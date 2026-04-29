# local-otel-tempo

A small, self-contained sandbox for learning the **OpenTelemetry Collector → Grafana Tempo** trace pipeline on a laptop. Everything runs inside a single [k3d](https://k3d.io) cluster on your Docker daemon — no cloud, no external services.

```
┌──────────────┐   OTLP/gRPC    ┌──────────────────┐   OTLP/traces   ┌─────────┐
│  demo-app    │ ─────────────▶ │  otel-collector  │ ──────────────▶ │  tempo  │
│ (FastAPI)    │                │   (contrib)      │                 └────┬────┘
└──────────────┘                │                  │  remote_write        │
                                │  spanmetrics  ───┼─────────────▶ ┌────────────┐
                                │  servicegraph ───┘               │ prometheus │
                                └──────────────────┘               └─────┬──────┘
                                                                         │
                                                          query traces   │ query metrics
                                                                         │
                                                                  ┌──────┴──────┐
                                                                  │   grafana   │
                                                                  └─────────────┘
```

The collector enriches every span with `host.*` and `k8s.*` attributes so you can see which machine and which pod produced it — that's the "data describing the local machine" angle, attached as resource metadata to traces from a real app.

---

## What's in here

| Path | What it is |
|---|---|
| `Makefile` | All operator-facing commands. `make help` for the menu. |
| `scripts/` | The shell scripts the Makefile drives (`prereqs.sh`, `up.sh`, `down.sh`, `traffic.sh`). |
| `helm/` | Values files for the four Helm charts: tempo, prometheus, otel-collector, grafana. |
| `demo-app/` | A ~50-line FastAPI service with three endpoints, fully OTel-instrumented. |

---

## Prerequisites

You need a Linux shell with Docker access. **WSL2 Ubuntu is the target** — instructions below assume that.

| Tool | Why | Auto-installable? |
|---|---|---|
| Docker | runs k3d's containers | **No** — install Docker Desktop on Windows, then enable WSL Integration for your distro |
| k3d | spins up a k3s cluster inside Docker | yes |
| kubectl | talks to the cluster | yes |
| helm | installs the charts | yes |

On a fresh WSL2 Ubuntu, the fastest path is:

```bash
make install-tools     # installs k3d, helm, kubectl (sudo prompt for kubectl)
make prereqs           # verify all four are now ok
```

`install-tools` is idempotent — anything already on PATH is skipped. Docker is the one piece it can't fix from inside WSL: install Docker Desktop on Windows, then **Settings → Resources → WSL Integration**, toggle on for your Ubuntu distro, Apply & Restart, and run `wsl --shutdown` from PowerShell before reopening the terminal.

---

## One-shot setup

```bash
make up
```

This will:

1. Create a k3d cluster called `otel-demo` (one server, no agents).
2. Publish host port `3000` onto the cluster's loadbalancer at port `80`, where Traefik (built into k3s) listens. The Grafana ingress then routes `localhost:3000` → Traefik → Grafana.
3. Install Tempo, Prometheus, the OpenTelemetry Collector, and Grafana via Helm into the `observability` namespace.
4. Build the demo app image, import it into the cluster, and deploy it into the `demo` namespace.

First run takes a few minutes (image pulls). Re-runs are quick — `helm upgrade --install` is idempotent.

> **You'll see `WARNING: This chart is deprecated`** when Tempo installs. That's expected: Grafana retired the simple `grafana/tempo` chart in favor of `grafana/tempo-distributed`. For a single-binary laptop demo it still works fine.

---

## Walkthrough — see your first trace

After `make up` finishes, generate some traffic:

```bash
make traffic
```

Then open Grafana:

```
http://localhost:3000
```

You're logged in as anonymous Admin (no password — see `helm/grafana-values.yaml`).

1. Left sidebar → **Explore**.
2. Top-left datasource picker → **Tempo**.
3. **Search** tab → click **Run query**. You should see your recent traces.
4. Click any trace.

### What you're looking at

For a `/work` request you should see a tree like:

```
GET /work                           ← created by FastAPIInstrumentor
  ├── fake-db-query                 ← manual span in app.py
  └── fake-http-call                ← manual span in app.py
```

Click the root span and look at the **Resource** attributes panel:

| Attribute | Source |
|---|---|
| `service.name` | the SDK, from `OTEL_SERVICE_NAME` env var |
| `service.namespace`, `deployment.environment` | the SDK, from `OTEL_RESOURCE_ATTRIBUTES` |
| `host.name`, `host.os.type`, `host.arch` | collector — `resourcedetection` processor |
| `k8s.pod.name`, `k8s.namespace.name`, `k8s.node.name`, `k8s.deployment.name` | collector — `k8sattributes` processor |

The app didn't set any of the `host.*` or `k8s.*` ones. The collector added them on the way through, by reading its own environment and by looking up the sender's pod in the k8s API. That's the part of OTel that often feels magical the first time you see it.

### `/error` traces

```bash
curl http://localhost:8080/error    # if you've port-forwarded
```

Or just let `make traffic` hit it randomly. In Grafana those traces show with a red status icon, and the **Events** tab on the `buggy-operation` span has a recorded `exception` event with the stack trace.

---

## The collector pipeline

Open `helm/otel-collector-values.yaml` and look at `config.service.pipelines`:

```yaml
traces:
  receivers:  [otlp]
  processors: [k8sattributes, resourcedetection, batch]
  exporters:  [otlp/tempo, spanmetrics, servicegraph, debug]

metrics:
  receivers:  [spanmetrics, servicegraph]
  processors: [batch]
  exporters:  [prometheusremotewrite]
```

That's the whole story:

- **otlp receiver** — listens on `4317` (gRPC) and `4318` (HTTP). The demo app sends gRPC.
- **k8sattributes** — adds the `k8s.*` attributes by looking up the sender's IP.
- **resourcedetection** — adds `host.*` from the node the collector is running on.
- **batch** — buffers spans for up to 2 seconds, then flushes. Standard hygiene.
- **otlp/tempo exporter** — forwards raw spans to Tempo.
- **spanmetrics / servicegraph connectors** — these are the magic pieces. They sit at the trace pipeline's *exporter* slot, but they also act as a *receiver* for the metrics pipeline. They watch traces fly by and emit derived metrics: span rate/error/duration histograms (`spanmetrics`) and edge counts/latencies between services (`servicegraph`).
- **prometheusremotewrite exporter** — pushes those metrics into Prometheus.
- **debug exporter** — also dumps a one-line summary to stdout for `kubectl logs`.

Watch the debug output flow by:

```bash
make logs-collector
```

You'll see each batch as it goes through.

## Service graph

In Grafana **Explore → Tempo**, click the **Service Graph** tab and **Run query**. You should see `demo-app` as a node. The data behind that view comes from Prometheus, populated by the `servicegraph` connector in the OTel collector — Tempo itself doesn't compute it.

Because our demo has only one service, the graph is unexciting (a single node, self-edge if the app calls itself). To see edges between services, you'd add a second service that calls `demo-app` (or have `demo-app` call out via real HTTP — the in-process `fake-http-call` span isn't a real edge because there's no remote receiver).

You can also query the raw metrics directly: in **Explore → Prometheus**, try:

```
sum by (service_name) (rate(traces_spanmetrics_calls_total[1m]))
```

That's RPS per service. Or:

```
histogram_quantile(0.95, sum by (le, service_name) (rate(traces_spanmetrics_duration_milliseconds_bucket[1m])))
```

p95 request duration. Both are produced by the `spanmetrics` connector with no app-side instrumentation — it derives them from spans.

---

## Things to try

- **Change the service name.** Edit `OTEL_SERVICE_NAME` in `demo-app/k8s.yaml`, `kubectl apply` the file, and watch new traces appear under the new name.
- **Add an attribute processor.** In `helm/otel-collector-values.yaml`, add an `attributes` processor that injects something like `deployment.environment: kasper-laptop` on every span. Re-apply with `helm upgrade` (or just `make up`).
- **Break the exporter.** Change the Tempo endpoint to a wrong port. Watch `make logs-collector` show retries; watch the debug exporter still print spans (the receiver and pipeline are fine — only the export fails).
- **Crank up the verbosity.** Switch the debug exporter from `verbosity: basic` to `detailed` and see the full span content in the collector logs. Don't leave it that way — it's chatty.
- **Add a second service** so the service graph actually has multiple nodes. The simplest way: deploy a second copy of `demo-app` under a different `OTEL_SERVICE_NAME` (call it `demo-caller`), and have it loop calls into `http://demo-app/work`. Two services, one real edge, a graph worth looking at.

---

## Operational cheat sheet

```bash
make help              # list all targets
make status            # pods in both namespaces
make logs-collector    # tail the OTel collector
make logs-tempo        # tail Tempo
make logs-prom         # tail Prometheus
make logs-app          # tail demo-app
make app               # rebuild + reload demo-app after a code change
make restart-app       # rollout restart without rebuilding
make traffic           # blast 30 mixed requests at the demo app
make down              # destroy the cluster
```

---

## Troubleshooting

**`make up` hangs on a Helm install.** Charts pull images on first run. If your network is slow, give it a minute. If a pod is stuck, `make status` and `kubectl -n observability describe pod <name>`.

**No traces appearing in Grafana.**
1. `make logs-app` — is the SDK printing connection errors?
2. `make logs-collector` — is the debug exporter printing batches? If yes, the path app→collector is fine and the issue is collector→tempo.
3. `kubectl -n observability get svc` — confirm the Service names match what the configs reference.

**Grafana isn't on `localhost:3000`.** The path is host:3000 → k3d loadbalancer:80 → Traefik → ingress rule → grafana svc. If any link breaks (e.g., the loadbalancer port mapping was set wrong, or another process on your host already owns port 3000), fall back to:

```bash
kubectl -n observability port-forward svc/grafana 3001:80
```

…and use `http://localhost:3001` instead. (We use `3001` here so it doesn't clash with whatever already holds 3000.)

**Docker Desktop is on, but `docker info` fails inside WSL.** Docker Desktop → Settings → Resources → WSL Integration → toggle your distro on (and restart the distro: `wsl --shutdown` from Windows, then re-open).

---

## Cleanup

```bash
make down
```

That deletes the entire k3d cluster — every pod, image cache, and volume goes with it. Nothing is left running on your host.
