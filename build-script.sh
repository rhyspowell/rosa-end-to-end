terraform apply

export SUBNET_IDS=$(terraform output -raw cluster-subnets-string)

export REGION=eu-west-1

echo "Check that password is set"
echo $CLUSTER_PASSWORD
if [ "${#CLUSTER_PASSWORD}" -lt 14 ]
then
	echo "Cluster password not long enough"
	exit 255
fi

echo "create account roles"
rosa create account-roles --hosted-cp --mode auto --prefix rhys-hcp  --yes

echo "create oidc config"
OIDC_CONFIG_ID=`rosa create oidc-config --mode auto -y --output json | jq -r '.id'`

echo "Create operator roles"
rosa create operator-roles --prefix rhys-hcp --oidc-config-id $OIDC_CONFIG_ID --hosted-cp --installer-role-arn arn:aws:iam::660250927410:role/rhys-hcp-HCP-ROSA-Installer-Role --mode auto -y

echo "create cluster"
rosa create cluster --cluster-name rhys-hcp --sts --role-arn arn:aws:iam::660250927410:role/rhys-hcp-HCP-ROSA-Installer-Role --support-role-arn arn:aws:iam::660250927410:role/rhys-hcp-HCP-ROSA-Support-Role --worker-iam-role arn:aws:iam::660250927410:role/rhys-hcp-HCP-ROSA-Worker-Role --operator-roles-prefix rhys-hcp --oidc-config-id $OIDC_CONFIG_ID --region $REGION --version 4.14.3 --replicas 3 --compute-machine-type m6a.xlarge --subnet-ids $SUBNET_IDS --hosted-cp

echo "watch cluster build"
rosa logs install -c rhys-hcp --watch

rosa create admin -c rhys-hcp -p $CLUSTER_PASSWORD 

sleep 60

CLUSTER_API=`rosa describe cluster -c rhys-hcp -o json | jq -r '.api.url'`

while True
do
	response=`oc login $CLUSTER_API --username cluster-admin --password $CLUSTER_PASSWORD -n`
	if [ $response = ^"Login successful." ]; then
		break 
	else
		sleep 60
	fi 
done

oc new-project gitops

oc apply -f openshift-gitops-sub.yaml

oc adm policy add-cluster-role-to-user cluster-admin -z openshift-gitops-argocd-application-controller -n openshift-gitops

argoURL=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}{"\n"}')
echo $argoURL

argoPass=$(oc get secret/openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d)
echo $argoPass

argocd login --insecure --grpc-web $argoURL  --username admin --password $argoPass

oc apply -f rhys-app.yaml
    
