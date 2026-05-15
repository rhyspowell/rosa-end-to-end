#!/bin/bash

# Check if quick_export.sh exists and execute it
if [ -f "quick_export.sh" ]; then
    echo "Found quick_export.sh - executing..."
    source quick_export.sh
fi

run_optional_install() {
    local dir="$1"
    echo "Run setup from $dir/"
    if [ -f "./$dir/run.sh" ]; then
        bash "./$dir/run.sh"
    elif compgen -G "./$dir/*.yaml" > /dev/null || compgen -G "./$dir/*.yml" > /dev/null; then
        oc apply -f "./$dir/"
    else
        echo "Nothing to run in $dir/ — add run.sh or YAML manifests"
        exit 1
    fi
}

ARGS=()
for arg in "$@"; do
    case "$arg" in
        --openshift-gitops) OPENSHIFT_GITOPS_ENABLED=true ;;
        --openshift-ai) OPENSHIFT_AI_ENABLED=true ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

while getopts c:r:v:p:t: flag
do
    case "${flag}" in
        c) CLUSTER_NAME=${OPTARG};;
        r) AWS_REGION=${OPTARG};;
        v) CLUSTER_VERSION=${OPTARG};;
        p) CLUSTER_PASSWORD=${OPTARG};;
        t) TAGS=${OPTARG};;
        m) MACHINE_TYPE=${OPTARG};;
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
    CLUSTER_VERSION="4.21.2"
fi

if [ -z "$TAGS" ]; then
    TAGS=""
fi

if [ -z "$MACHINE_TYPE" ]; then
    MACHINE_TYPE="m6a.xlarge"
fi

echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_VERSION: $CLUSTER_VERSION"

echo "Get terrafrom ready"
terraform init -upgrade

echo "Apply terraform"

terraform apply -auto-approve

export SUBNET_IDS=$(terraform output -raw cluster-subnets-string)


echo "Check that password is set"
if [ "${#CLUSTER_PASSWORD}" -lt 14 ]
then
	echo "Cluster password not long enough"
	exit 255
fi

echo "Check that you are logged into ocm"
OCM_WHOAMI_OUTPUT=$(ocm whoami 2>&1 || true)
if [[ $OCM_WHOAMI_OUTPUT == Error* ]]; then
    echo "You are not logged into OCM: $OCM_WHOAMI_OUTPUT"
    echo "Lets get you logged in. You will need to use your browser to login."
    ocm login --use-auth-code
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
rosa create cluster --cluster-name $CLUSTER_NAME --sts --role-arn arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER_NAME-HCP-ROSA-Installer-Role --support-role-arn arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER_NAME-HCP-ROSA-Support-Role --worker-iam-role arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER_NAME-HCP-ROSA-Worker-Role --operator-roles-prefix $CLUSTER_NAME --oidc-config-id $OIDC_CONFIG_ID --region $AWS_REGION --version $CLUSTER_VERSION --replicas 3 --compute-machine-type $MACHINE_TYPE --subnet-ids $SUBNET_IDS --hosted-cp --billing-account $ACCOUNT_ID --tags="$TAGS"

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

# Add additional users to the cluster
ocm create idp -t htpasswd -c $CLUSTER_NAME -n developer-dave --username developer-dave --password $CLUSTER_PASSWORD
ocm create idp -t htpasswd -c $CLUSTER_NAME -n developer-dan --username developer-dan --password $CLUSTER_PASSWORD

if [ "$OPENSHIFT_GITOPS_ENABLED" = true ]; then
    run_optional_install openshift-gitops
fi

if [ "$OPENSHIFT_AI_ENABLED" = true ]; then
    run_optional_install openshift-ai
fi

echo "Cluster info thats available right now"
echo "Some end points might not yet be ready"
echo ""
dns=`rosa describe cluster -c $CLUSTER_NAME -o json | jq -r .dns.base_domain`
echo "https://console-openshift-console.apps.rosa.$CLUSTER_NAME$CLUSTER_DOMAIN.$dns"
echo ""
if [ "$OPENSHIFT_GITOPS_ENABLED" = true ]; then
	echo "Main Argo CD url"
	oc get route openshift-gitops-server -n openshift-gitops -o json | jq -r .spec.host
	oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d
	# echo ""
	# echo "Developer Dave ArgoCD"
	# oc get route developer-dave-argocd-server -n developer-dave -o json | jq -r .spec.host
	# oc get secret developer-dave-argocd-cluster  -n developer-dave -o jsonpath='{.data.admin\.password}' | base64 -d
    # echo ""
	# echo "Developer Dan ArgoCD"
	# oc get route developer-dan-argocd-server -n developer-dan -o json | jq -r .spec.host
	# oc get secret developer-dan-argocd-cluster  -n developer-dan -o jsonpath='{.data.admin\.password}' | base64 -d
fi
