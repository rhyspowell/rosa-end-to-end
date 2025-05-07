#!/bin/bash

# Check if quick_export.sh exists and execute it
if [ -f "quick_export.sh" ]; then
    echo "Found quick_export.sh - executing..."
    source quick_export.sh
fi

while getopts c:r:v:p: flag
do
    case "${flag}" in
        c) CLUSTER_NAME=${OPTARG};;
        r) AWS_REGION=${OPTARG};;
        v) CLUSTER_VERSION=${OPTARG};;
        p) CLUSTER_PASSWORD=${OPTARG};;
    esac
done

# Set default cluster name if not already set
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME="test-hcp"
fi

# Set default region if not already set
if [ -z "$AWS_REGION" ]; then
    AWS_REGION="eu-west-2"
fi

# Set default version if not already set
if [ -z "$CLUSTER_VERSION" ]; then
    CLUSTER_VERSION="4.17.16"
fi


echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_VERSION: $CLUSTER_VERSION"

exit 0

echo "Apply terraform"

terraform apply -auto-approve

export SUBNET_IDS=$(terraform output -raw cluster-subnets-string)


echo "Check that password is set"
if [ "${#CLUSTER_PASSWORD}" -lt 14 ]
then
	echo "Cluster password not long enough"
	exit 255
fi

echo "create account roles"
rosa create account-roles -f --hosted-cp --mode auto --prefix $CLUSTER_NAME --region $AWS_REGION --yes 

echo "create oidc config"
OIDC_CONFIG_ID=`rosa create oidc-config --mode auto -y --region $AWS_REGION --output json | jq -r '.id'`
echo $OIDC_CONFIG_ID > oidc_config_id.txt

echo "Create OIDC provider"
rosa create oidc-provider --oidc-config-id $OIDC_CONFIG_ID --region $AWS_REGION --mode auto -y

ACCOUNT_ID=`aws sts get-caller-identity --query 'Account' --output text`
echo "Account id $ACCOUNT_ID"
echo "Create operator roles"
rosa create operator-roles --prefix $CLUSTER_NAME --oidc-config-id $OIDC_CONFIG_ID --hosted-cp --installer-role-arn arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER_NAME-HCP-ROSA-Installer-Role --region $AWS_REGION --mode auto -y

echo "create cluster"
rosa create cluster --cluster-name $CLUSTER_NAME --sts --role-arn arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER_NAME-HCP-ROSA-Installer-Role --support-role-arn arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER_NAME-HCP-ROSA-Support-Role --worker-iam-role arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER_NAME-HCP-ROSA-Worker-Role --operator-roles-prefix $CLUSTER_NAME --oidc-config-id $OIDC_CONFIG_ID --region $AWS_REGION --version $CLUSTER_VERSION --replicas 3 --compute-machine-type m6a.xlarge --subnet-ids $SUBNET_IDS --hosted-cp --billing-account $ACCOUNT_ID

echo "watch cluster build"
rosa logs install -c $CLUSTER_NAME  --region $AWS_REGION --watch

rosa create admin -c $CLUSTER_NAME -p "$CLUSTER_PASSWORD" --region $AWS_REGION

sleep 60

CLUSTER_API=`rosa describe cluster -c $CLUSTER_NAME --region $AWS_REGION -o json | jq -r '.api.url'`

sucessful_login="^Login successful*"
while True
do
	response=`oc login $CLUSTER_API --username cluster-admin --password $CLUSTER_PASSWORD`
	echo $response
	if [[ $response =~ $sucessful_login ]]; then
		echo "Break"
		break
	else
		sleep 60
	fi 
done

# echo "Create new project"
# oc new-project gitops

# echo "Apply RF gitops subscription"
# oc apply -f ./openshift-gitops-sub.yaml

# sleep 60

# echo "Grab gitops url"
# argo_route="^openshift-gitops-server-openshift-gitops*"
# while True
# do
# 	argoURL=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}{"\n"}')
# 	if [[ $argoURL =~ $argo_route ]]; then
# 		break
# 	else
# 		sleep 10
# 	fi
# done

# echo $argoURL

# echo "Grab gitops password"
# argoPass=$(oc get secret/openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d)
# echo $argoPass

# echo "Login to argo"
# argo_logged_in="^'admin:login' logged in successfully*"
# while True
# do
# 	argo_login=$(argocd login --insecure --grpc-web $argoURL  --username admin --password $argoPass)
# 	if [[ $argo_login =~ $argo_logged_in ]]; then
# 	echo "Logged in"
# 		break
# 	else
# 		sleep 10
# 	fi
# done

# # Set edge reencrypt
# # https://access.redhat.com/solutions/6041341
# oc -n openshift-gitops patch argocd/openshift-gitops --type=merge -p='{"spec":{"server":{"route":{"enabled":true,"tls":{"insecureEdgeTerminationPolicy":"Redirect","termination":"reencrypt"}}}}}'

# echo "Apply the gitops"
# oc apply -f ./rhys-app.yaml

# sleep 30
# oc -n rhys-argocd patch argocd/rhys-argocd --type=merge -p='{"spec":{"server":{"route":{"enabled":true,"tls":{"insecureEdgeTerminationPolicy":"Redirect","termination":"reencrypt"}}}}}'

echo "Cluster info thats available right now"
echo "Some end points might not yet be ready"
echo ""
dns=`rosa describe cluster -c $CLUSTER_NAME --region $REGION -o json | jq -r .dns.base_domain`
echo "https://console-openshift-console.apps.rosa.$CLUSTER_NAME$CLUSTER_DOMAIN.$dns"
echo ""
echo "Main Argo CD url"
oc get route openshift-gitops-server -n openshift-gitops -o json | jq -r .spec.host
oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d
echo ""
echo "Namespace ArgoCD"
oc get route rhys-argocd-server -n rhys-argocd -o json | jq -r .spec.host
oc get secret rhys-argocd-cluster  -n rhys-argocd -o jsonpath='{.data.admin\.password}' | base64 -d
