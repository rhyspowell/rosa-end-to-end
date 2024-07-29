export AWS_REGION=eu-west-2
CLUSTER_NAME="rhys-hcp"
while getopts c: flag
do
    case "${flag}" in
        c) CLUSTER_NAME=${OPTARG};;
    esac
done

# oidc_config_id=`rosa describe cluster -c rhys-hcp -o json | jq -r .aws.sts.oidc_config.id`
oidc_config_id=`cat oidc_config_id.txt`

rosa delete cluster -c $CLUSTER_NAME -y
echo "watch cluster uninstall"
rosa logs uninstall -c $CLUSTER_NAME --watch


rosa delete operator-roles --prefix $CLUSTER_NAME --mode auto -y
rosa delete account-roles --hosted-cp --mode auto --prefix $CLUSTER_NAME -y
rosa delete oidc-provider --oidc-config-id $oidc_config_id --mode auto -y
rosa delete oidc-config --oidc-config-id $oidc_config_id --mode auto -y

rm oidc_config_id.txt

terraform destroy -auto-approve
