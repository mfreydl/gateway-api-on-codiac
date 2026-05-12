#!/usr/bin/env bash
# Phase 2: Provision the AKS cluster using the custom stack built in Phase 1.
# Adjust the variables below before running.
set -euo pipefail

CLUSTER_NAME="my-gateway-cluster"
AZURE_SUBSCRIPTION="<your-azure-subscription-id>"   # e.g. xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
RESOURCE_GROUP="gateway-poc-rg"
LOCATION="eastus"
NODE_SPEC="Standard_D4s_v3"
NODE_QTY=2
K8S_VERSION="1.30.0"

echo "=== Bootstrapping AKS cluster: ${CLUSTER_NAME} ==="
echo "    Provider:      azure"
echo "    Subscription:  ${AZURE_SUBSCRIPTION}"
echo "    Resource group: ${RESOURCE_GROUP}"
echo "    Location:      ${LOCATION}"
echo "    Node spec:     ${NODE_SPEC} x${NODE_QTY}"
echo "    K8s version:   ${K8S_VERSION}"
echo ""

cod cluster bootstrap "${CLUSTER_NAME}" \
  --provider azure \
  --providerSubscription "${AZURE_SUBSCRIPTION}" \
  --resourceGroup "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --nodeSpec "${NODE_SPEC}" \
  --nodeQty "${NODE_QTY}" \
  --k8sVersion "${K8S_VERSION}" \
  --wait \
  --silent

echo ""
echo "Done. Cluster bootstrapped with NGINX Gateway Fabric cluster stack."
echo "Verify with: kubectl get pods -n nginx-gateway"
echo "Proceed to 03-setup-sdlc.sh"
