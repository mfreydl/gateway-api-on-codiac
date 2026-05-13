#!/usr/bin/env bash
# Phase 3: Register SDLC assets in the built-in "main" enterprise,
# create an environment and cabinet, configure routes, and deploy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

ENTERPRISE="main"
CLUSTER="my-gateway-cluster"
ENV_NAME="dev"
CABINET="dev-01"

# -------------------------------------------------------------------------
echo "=== Step 1: Register the web server asset (nginx:alpine) ==="
cod asset create -e "${ENTERPRISE}" \
  --name webapp \
  --type service \
  --image "nginx:alpine" \
  --port 80 \
  --no-ingress

# -------------------------------------------------------------------------
echo "=== Step 2: Register the SFTP server asset (atmoz/sftp) ==="
cod asset create -e "${ENTERPRISE}" \
  --name sftpd \
  --type service \
  --image "atmoz/sftp" \
  --port 22 \
  --no-ingress

# -------------------------------------------------------------------------
echo "=== Step 3: Configure SFTP user credentials ==="
# Format: "username:password:uid[:gid[:dir1[,dir2],...]]"
cod config add -e "${ENTERPRISE}" -a sftpd \
  -t env --enterprise-scope \
  --setting "SFTP_USERS" \
  --value "demouser:changeme123:1001" \
  --silent

# -------------------------------------------------------------------------
echo "=== Step 4: Create environment and cabinet ==="
cod env add --enterprise "${ENTERPRISE}" --name "${ENV_NAME}"
cod cabinet create --enterprise "${ENTERPRISE}" --environment "${ENV_NAME}" --name "${CABINET}"
cod cabinet cluster attach --enterprise "${ENTERPRISE}" --cabinet "${CABINET}" --cluster "${CLUSTER}"

# -------------------------------------------------------------------------
echo "=== Step 5: Configure HTTPRoute for webapp (onPostDeploy, cabinet scope) ==="
# The manifest uses ${cabinet.namespace} — resolved at deploy time by the Codiac relay.
cod config add -e "${ENTERPRISE}" -a webapp \
  -c "${CABINET}" \
  -t onpostdeploy \
  --setting "01-http-route" \
  --value-stdin < "${MANIFEST_DIR}/webapp-httproute.yaml" \
  --silent

# -------------------------------------------------------------------------
echo "=== Step 6: Configure TCPRoute for sftpd (onPostDeploy, cabinet scope) ==="
cod config add -e "${ENTERPRISE}" -a sftpd \
  -c "${CABINET}" \
  -t onpostdeploy \
  --setting "01-tcp-route" \
  --value-stdin < "${MANIFEST_DIR}/sftpd-tcproute.yaml" \
  --silent

# -------------------------------------------------------------------------
echo "=== Step 7: Deploy assets ==="
cod asset deploy -e "${ENTERPRISE}" -a webapp -c "${CABINET}" -u latest --wait --silent
cod asset deploy -e "${ENTERPRISE}" -a sftpd -c "${CABINET}" -u latest --wait --silent

echo ""
echo "Done. Proceed to verification:"
CABINET_NS="${ENTERPRISE}-${ENV_NAME}-${CABINET}"
echo "  kubectl get gateway -n nginx-gateway"
echo "  kubectl get httproute -n ${CABINET_NS}"
echo "  kubectl get tcproute -n ${CABINET_NS}"
EXTERNAL_IP=$(kubectl get svc -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")
echo "  Gateway external IP: ${EXTERNAL_IP}"
echo "  curl http://${EXTERNAL_IP}/"
echo "  sftp -P 22 demouser@${EXTERNAL_IP}"
