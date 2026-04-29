#!/usr/bin/env bash
set -euo pipefail

# Generate traffic against the demo app to produce traces.
# Uses kubectl port-forward in the background so it works regardless of
# whether you've already forwarded the service yourself.

DEMO_NS=${DEMO_NS:-demo}
COUNT=${COUNT:-30}
LOCAL_PORT=${LOCAL_PORT:-18080}

cleanup() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

kubectl -n "$DEMO_NS" port-forward svc/demo-app "$LOCAL_PORT:80" >/dev/null 2>&1 &
PF_PID=$!

# wait for the forward to be ready
for _ in $(seq 1 20); do
  curl -fsS "http://localhost:$LOCAL_PORT/" >/dev/null 2>&1 && break
  sleep 0.25
done

echo "Sending $COUNT requests to demo-app..."
for i in $(seq 1 "$COUNT"); do
  case $((RANDOM % 5)) in
    0|1|2) endpoint="/" ;;
    3)     endpoint="/work" ;;
    4)     endpoint="/error" ;;
  esac
  status=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$LOCAL_PORT$endpoint" || echo "000")
  printf '  %3d  %3s  %s\n' "$i" "$status" "$endpoint"
done

echo
echo "Done. Open Grafana → Explore → Tempo → 'Search' to find your traces."
