#!/bin/bash
# OpenShift AI setup — invoked by build-script.sh when --openshift-ai is passed.
# Add manifests, operator installs, or oc/rosa commands below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for manifest in "$SCRIPT_DIR"/*.yaml "$SCRIPT_DIR"/*.yml; do
    if [ -f "$manifest" ]; then
        echo "Applying $manifest"
        oc apply -f "$manifest"
    fi
done
