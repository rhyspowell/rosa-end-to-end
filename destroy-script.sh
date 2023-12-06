export AWS_REGION=eu-west-1

oidc_config_id=`rosa describe cluster -c rhys-hcp -o json | jq -r .aws.sts.oidc_config.id`

rosa delete cluster -c rhys-hcp -y
echo "watch cluster uninstall"
rosa logs uninstall -c rhys-hcp --watch


rosa delete operator-roles --prefix rhys-hcp --mode auto -y
rosa delete account-roles --hosted-cp --mode auto --prefix rhys-hcp -y
rosa delete oidc-provider --oidc-config-id $oidc_config_id --mode auto -y

terraform destroy -auto-approve
