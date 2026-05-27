#!/usr/bin/env bash
# Phase 1: Build the custom k8sinfrx cluster stack with NGINX Gateway Fabric
# Run BEFORE provisioning the cluster.
set -euo pipefail

ENTERPRISE="k8sinfrx"
ASSET_NGF="nginx-gateway-fabric"

echo "=== Step 1: Capture the built-in cluster stack ==="
cod cluster stack capture

echo "=== Step 2: Remove ingress-nginx from the stack ==="
cod asset obliterate -e "${ENTERPRISE}" -a ingress-nginx --silent

echo "=== Step 3: Register NGINX Gateway Fabric as a Helm asset ==="
# NGINX Gateway Fabric OCI Helm chart: oci://ghcr.io/nginx/charts/nginx-gateway-fabric
cod asset create --enterprise "${ENTERPRISE}" \
  --helm \
  --name "${ASSET_NGF}" \
  --code "${ASSET_NGF}" \
  --image nginx-gateway-fabric \
  --registry helm|artifactHub|nginx-gateway-fabric \
  --silent

echo "=== Step 4: Configure onPreDeploy — install Gateway API experimental CRDs ==="
cod config add -n "${ENTERPRISE}" -a "${ASSET_NGF}" \
  -t onpredeploy --enterprise-scope \
  --setting "01-gateway-api-crds" \
  --value "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/experimental-install.yaml" \
  --silent

echo "=== Step 5: Configure Helm values for NGINX Gateway Fabric ==="

# LoadBalancer service so AKS assigns a public IP
cod config add -n "${ENTERPRISE}" -a "${ASSET_NGF}" \
  -t helm --enterprise-scope \
  --setting "service.type" --value "LoadBalancer" --silent

# GatewayClass name this controller manages
cod config add -n "${ENTERPRISE}" -a "${ASSET_NGF}" \
  -t helm --enterprise-scope \
  --setting "gatewayClass.name" --value "nginx" --silent

# Expose port 22 on the LoadBalancer for SFTP TCP routing
cod config add -n "${ENTERPRISE}" -a "${ASSET_NGF}" \
  -t helm --enterprise-scope \
  --setting "service.extraTcpPorts[0].name" --value "sftp" --silent

cod config add -n "${ENTERPRISE}" -a "${ASSET_NGF}" \
  -t helm --enterprise-scope \
  --setting "service.extraTcpPorts[0].port" --value "22" --silent

cod config add -n "${ENTERPRISE}" -a "${ASSET_NGF}" \
  -t helm --enterprise-scope \
  --setting "service.extraTcpPorts[0].targetPort" --value "22" --silent

echo "=== Step 6: Configure onPostDeploy — apply the Gateway CR ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

cod config add -n "${ENTERPRISE}" -a "${ASSET_NGF}" \
  -t onpostdeploy --enterprise-scope  \
  --setting "01-gateway-cr" \
  --value-stdin < "${MANIFEST_DIR}/gateway.yaml" \
  --silent

# -------------------------------------------------------------
# TODO: The steps below reflect a slight misunderstanding of the stack capture and stack tag commands.  Need a command to assemble a cluster stack version and tagging it without deploying it.  It's an alchemy command (declaring indiv asset versions, starting from an existing stack version or empty), just without the deploy.

# echo "=== Step 7: Capture a version of the modified stack ==="
# cod cluster stack capture

# echo "=== Step 8: Tag it as the default stack ==="
# cod cluster stack tag --tag default
# -------------------------------------------------------------


echo ""
echo "Done. Custom cluster stack is ready. Proceed to 02-provision-cluster.sh"
