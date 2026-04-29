#!/usr/bin/env bash
set -euo pipefail

# Bring up the full local stack:
#   1. k3d cluster
#   2. helm repos
#   3. tempo, otel-collector, grafana (in namespace `observability`)
#   4. demo-app image build + import + deploy (in namespace `demo`)

CLUSTER_NAME=${CLUSTER_NAME:-otel-demo}
OBS_NS=${OBS_NS:-observability}
DEMO_NS=${DEMO_NS:-demo}
DEMO_IMAGE=${DEMO_IMAGE:-demo-app:local}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step "Ensuring k3d cluster '$CLUSTER_NAME' exists"
if ! k3d cluster list -o json | grep -q "\"name\": *\"$CLUSTER_NAME\""; then
  # Publish host:3000 onto the k3d loadbalancer's :80 (where Traefik listens
  # inside the cluster). The Grafana ingress in helm/grafana-values.yaml
  # then routes localhost:3000 → Traefik → Grafana svc → Grafana pod.
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 --agents 0 \
    --port "3000:80@loadbalancer" \
    --wait
else
  echo "cluster '$CLUSTER_NAME' already exists — reusing"
fi

# Make sure kubectl context is pointing at our cluster
kubectl config use-context "k3d-$CLUSTER_NAME" >/dev/null

step "Adding/updating helm repos"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

step "Creating namespaces"
kubectl get ns "$OBS_NS"  >/dev/null 2>&1 || kubectl create ns "$OBS_NS"
kubectl get ns "$DEMO_NS" >/dev/null 2>&1 || kubectl create ns "$DEMO_NS"

step "Installing Tempo (monolithic, filesystem storage)"
helm upgrade --install tempo grafana/tempo \
  --namespace "$OBS_NS" \
  --values "$ROOT_DIR/helm/tempo-values.yaml" \
  --wait

step "Installing Prometheus (remote-write receiver for span/service-graph metrics)"
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace "$OBS_NS" \
  --values "$ROOT_DIR/helm/prometheus-values.yaml" \
  --wait

step "Installing OpenTelemetry Collector"
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace "$OBS_NS" \
  --values "$ROOT_DIR/helm/otel-collector-values.yaml" \
  --wait

step "Installing Grafana"
helm upgrade --install grafana grafana/grafana \
  --namespace "$OBS_NS" \
  --values "$ROOT_DIR/helm/grafana-values.yaml" \
  --wait

step "Building demo-app image"
docker build -t "$DEMO_IMAGE" "$ROOT_DIR/demo-app"

step "Importing demo-app image into k3d"
k3d image import "$DEMO_IMAGE" --cluster "$CLUSTER_NAME"

step "Deploying demo-app"
kubectl apply -n "$DEMO_NS" -f "$ROOT_DIR/demo-app/k8s.yaml"
kubectl rollout status -n "$DEMO_NS" deploy/demo-app --timeout=120s

step "Done"
cat <<EOF

  Grafana:    http://localhost:3000   (anonymous viewer; no login required)
              Explore → Tempo → Search        (traces)
              Explore → Tempo → Service Graph (driven by Prometheus metrics)
              Explore → Prometheus            (raw spanmetrics queries)

  Demo app:   kubectl -n $DEMO_NS port-forward svc/demo-app 8080:80
              then: curl http://localhost:8080/work

  Generate traffic:    make traffic
  View collector logs: make logs-collector
  Tear down:           make down

EOF
