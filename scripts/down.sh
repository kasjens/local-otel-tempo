#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-otel-demo}

if k3d cluster list -o json | grep -q "\"name\": *\"$CLUSTER_NAME\""; then
  echo "Deleting k3d cluster '$CLUSTER_NAME'..."
  k3d cluster delete "$CLUSTER_NAME"
else
  echo "Cluster '$CLUSTER_NAME' does not exist — nothing to do."
fi
