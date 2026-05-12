#!/usr/bin/env bash
# Cleanup: undeploy assets and destroy the cluster.
# Routes (HTTPRoute, TCPRoute) and the Gateway CR are deleted automatically
# via the onPostDeploy LIFO teardown sequence in the Codiac relay.
set -euo pipefail

ENTERPRISE="gateway-poc-apps"
CLUSTER="my-gateway-cluster"
CABINET="dev-01"

echo "=== Undeploy SDLC assets (routes auto-deleted via onPostDeploy LIFO) ==="
cod asset undeploy -e "${ENTERPRISE}" -a webapp -c "${CABINET}" --silent
cod asset undeploy -e "${ENTERPRISE}" -a sftpd -c "${CABINET}" --silent

echo "=== Destroy the cluster (also removes all k8sinfrx assets) ==="
cod cluster destroy "${CLUSTER}"

echo "Done."
