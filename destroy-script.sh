#!/bin/bash

# Check if quick_export.sh exists and execute it
if [ -f "quick_export.sh" ]; then
    echo "Found quick_export.sh - executing..."
    source quick_export.sh
fi

while getopts c:r: flag
do
    case "${flag}" in
        c) CLUSTER_NAME=${OPTARG};;
        r) AWS_REGION=${OPTARG};;
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

echo "Check that you are logged into ocm"
OCM_WHOAMI_OUTPUT=$(ocm whoami 2>&1 || true)
if [[ $OCM_WHOAMI_OUTPUT == Error* ]]; then
    echo "You are not logged into OCM: $OCM_WHOAMI_OUTPUT"
    echo "Lets get you logged in. You will need to use your browser to login."
    ocm login --use-auth-code
fi

# oidc_config_id=`rosa describe cluster -c rhys-hcp -o json | jq -r .aws.sts.oidc_config.id`
oidc_config_id=`cat oidc_config_id.txt`

rosa delete cluster -c $CLUSTER_NAME -y
echo "watch cluster uninstall"
rosa logs uninstall -c $CLUSTER_NAME --watch


rosa delete operator-roles --prefix $CLUSTER_NAME --mode auto -y
rosa delete account-roles --hosted-cp --mode auto --prefix $CLUSTER_NAME -y
rosa delete oidc-provider --oidc-config-id $oidc_config_id --mode auto -y
rosa delete oidc-config --oidc-config-id $oidc_config_id --mode auto -y

#rm oidc_config_id.txt

terraform destroy -auto-approve
