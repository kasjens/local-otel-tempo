SHELL := /usr/bin/env bash

CLUSTER_NAME ?= otel-demo
OBS_NS       ?= observability
DEMO_NS      ?= demo
DEMO_IMAGE   ?= demo-app:local

export CLUSTER_NAME OBS_NS DEMO_NS DEMO_IMAGE

.PHONY: help prereqs install-tools up down app traffic grafana \
        logs-collector logs-tempo logs-app \
        status restart-app

help:    ## show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

prereqs: ## verify required tools (docker, k3d, kubectl, helm)
	@bash scripts/prereqs.sh

install-tools: ## install k3d, helm, and kubectl if missing (sudo prompt)
	@bash scripts/install-tools.sh

up: prereqs ## create cluster, install everything, deploy demo-app
	@bash scripts/up.sh

down:    ## delete the k3d cluster (full reset)
	@bash scripts/down.sh

app:     ## rebuild demo-app image and reload it into the cluster
	docker build -t $(DEMO_IMAGE) demo-app
	k3d image import $(DEMO_IMAGE) --cluster $(CLUSTER_NAME)
	kubectl -n $(DEMO_NS) rollout restart deploy/demo-app
	kubectl -n $(DEMO_NS) rollout status deploy/demo-app --timeout=120s

traffic: ## generate sample requests against the demo-app
	@bash scripts/traffic.sh

grafana: ## print the URL Grafana is reachable on
	@echo "Grafana: http://localhost:3000  (anonymous, admin role)"
	@echo "Fallback (host port 3000 is busy or ingress is broken):"
	@echo "    kubectl -n $(OBS_NS) port-forward svc/grafana 3001:80"
	@echo "    then: http://localhost:3001"

logs-collector: ## tail otel-collector logs
	kubectl -n $(OBS_NS) logs -l app.kubernetes.io/name=opentelemetry-collector -f --tail=100

logs-tempo:     ## tail tempo logs
	kubectl -n $(OBS_NS) logs -l app.kubernetes.io/name=tempo -f --tail=100

logs-prom:      ## tail prometheus logs
	kubectl -n $(OBS_NS) logs -l app.kubernetes.io/name=prometheus -f --tail=100

logs-app:       ## tail demo-app logs
	kubectl -n $(DEMO_NS) logs -l app=demo-app -f --tail=100

status:  ## show pods in both namespaces
	@echo "--- $(OBS_NS) ---"
	@kubectl -n $(OBS_NS) get pods
	@echo
	@echo "--- $(DEMO_NS) ---"
	@kubectl -n $(DEMO_NS) get pods

restart-app: ## kubectl rollout restart of the demo-app
	kubectl -n $(DEMO_NS) rollout restart deploy/demo-app
