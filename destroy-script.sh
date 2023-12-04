export AWS_REGION=eu-west-1

cluster_details=`rosa describe cluster -c rhys-hcp -o json`
cluster_id=`cat $cluster_details | jq .id`
operator_role_prefix=`cat $cluster_details | jq .aws.sts.operator_iam_roles.operator_role_prefix`

rosa delete cluster -c rhys-hcp -y
echo "watch cluster uninstall"
rosa logs uninstall -c rhys-hcp --watch

rosa delete oidc-provider --oidc-config-id $cluster_id --mode auto -y
rosa delete operator-roles --cluster rhys-hcp --mode auto -y
rosa delete account-roles --hosted-cp --mode auto --prefix rhys-hcp --yes
rosa delete oidc-config --oidc-config-id $cluster_id --mode auto -y

terraform destroy -y
