#!/bin/bash
# OpenShift GitOps setup — invoked by build-script.sh when --openshift-gitops is passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Apply RH gitops subscription"
oc apply -f "$SCRIPT_DIR/openshift-gitops-sub.yaml"

sleep 60

echo "Grab gitops url"
argo_route="^openshift-gitops-server-openshift-gitops*"
while True
do
    argoURL=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}{"\n"}')
    if [[ $argoURL =~ $argo_route ]]; then
        break
    else
        sleep 10
    fi
done

echo $argoURL

echo "Grab gitops password"
argoPass=$(oc get secret/openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d)
echo $argoPass

echo "Login to argo"
argo_logged_in="^'admin:login' logged in successfully*"
while True
do
    argo_login=$(argocd login --insecure --grpc-web $argoURL  --username admin --password $argoPass)
    if [[ $argo_login =~ $argo_logged_in ]]; then
        echo "Logged in"
        break
    else
        sleep 10
    fi
done

# Set edge reencrypt
# https://access.redhat.com/solutions/6041341
# Apparently fix no longer needed as of v1.13, this was wring but should be in the soon release
oc -n openshift-gitops patch argocd/openshift-gitops --type=merge -p='{"spec":{"server":{"route":{"enabled":true,"tls":{"insecureEdgeTerminationPolicy":"Redirect","termination":"reencrypt"}}}}}'

echo "Apply the bootstrap"
oc apply -f "$SCRIPT_DIR/bootstrap.yaml"

sleep 60
