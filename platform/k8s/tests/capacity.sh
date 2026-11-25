#!/usr/bin/env bash
# Step load test: k6 holds each arrival rate for STEP seconds through the in-cluster Service.
# Per step it records p95, errors and dropped iterations, plus the USE signals Kubernetes exposes
# (CPU/memory utilization from metrics-server, api replicas, restarts). Finds where the system bends.
#   platform/k8s/tests/capacity.sh <namespace> <rate> [rate...]
set -uo pipefail
NS=$1; shift
STEP=${STEP:-60}
kc() { kubectl --context kind-orderlab -n "$NS" "$@"; }
printf '%-6s %-9s %-9s %-8s %-8s %-9s %s\n' rate p95_ms p99_ms failed dropped replicas cpu/mem
for rate in "$@"; do
  kc delete pod k6 --ignore-not-found >/dev/null
  out=$(mktemp)
  kc run k6 -i --restart=Never --image=grafana/k6:2.3.0 --env=BASE_URL=http://api:8000 \
    --env=RATE="$rate" --env=DURATION="${STEP}s" -- run --quiet - <"$(dirname "$0")/orders-load.js" >"$out" 2>&1 &
  k6=$!
  sleep $((STEP * 3 / 4))
  # Sampled late in the step, when the HPA has had time to react.
  use=$(kc top pods --no-headers 2>/dev/null | awk '{printf "%s=%s/%s ", $1, $2, $3}')
  if kc get rollout api >/dev/null 2>&1; then
    replicas=$(kc get rollout api -o jsonpath='{.status.readyReplicas}')
  else
    replicas=$(kc get deployment api -o jsonpath='{.status.readyReplicas}')
  fi
  wait $k6
  line=$(grep -m1 'http_req_duration' "$out")
  p95=$(grep -oE 'p\(95\)=[^ ]+' <<<"$line" | cut -d= -f2)
  p99=$(grep -oE 'p\(99\)=[^ ]+' <<<"$line" | cut -d= -f2)
  failed=$(grep -E 'http_req_failed' "$out" | grep -oE '[0-9.]+%' | head -1)
  dropped=$(grep -E 'dropped_iterations' "$out" | awk '{print $2}')
  printf '%-6s %-9s %-9s %-8s %-8s %-9s %s\n' "$rate" "$p95" "$p99" "${failed:-?}" "${dropped:-0}" "$replicas" "$use"
  cp "$out" "${EVIDENCE_DIR:-/tmp}/k6-rate-$rate.txt" 2>/dev/null
  rm -f "$out"
done
kc delete pod k6 --ignore-not-found >/dev/null
kc get pods -l app.kubernetes.io/name=api -o custom-columns=POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount
