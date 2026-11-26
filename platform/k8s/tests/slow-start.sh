#!/usr/bin/env bash
# Keep live order traffic flowing while a deliberately slow Argo candidate starts.
# This checks startup probes and zero container restarts; the release gate has its own fault drill.
set -euo pipefail

NS=${1:-orderlab-staging}
K6_IMAGE=${K6_IMAGE:-grafana/k6:2.3.0}
RATE=${RATE:-20}
DURATION=${DURATION:-480s}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-360s}
LOAD_SCRIPT=platform/k8s/tests/orders-load.js
LOG=${TMPDIR:-/tmp}/slow-start-k6.log
kc() { kubectl --context kind-orderlab -n "$NS" "$@"; }

traffic_pid=
traffic_pod=slow-start-k6
changed=0
finished=0

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$changed" = 1 ] && [ "$finished" != 1 ]; then
    kubectl argo rollouts --context kind-orderlab -n "$NS" abort api >/dev/null 2>&1 || true
    kubectl argo rollouts --context kind-orderlab -n "$NS" undo api >/dev/null 2>&1 || true
    kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout="$ROLLOUT_TIMEOUT" >/dev/null 2>&1 || true
  fi
  if [ -n "$traffic_pid" ]; then kill "$traffic_pid" 2>/dev/null || true; fi
  if [ -n "$traffic_pod" ]; then kc delete pod "$traffic_pod" --ignore-not-found >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap cleanup EXIT INT TERM

kc get rollout api >/dev/null
kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout="$ROLLOUT_TIMEOUT"
kc delete pod "$traffic_pod" --ignore-not-found >/dev/null
kc run "$traffic_pod" -i --restart=Never --image="$K6_IMAGE" \
  --env=BASE_URL=http://api:8000 --env=RATE="$RATE" --env=DURATION="$DURATION" \
  -- run --quiet - <"$LOAD_SCRIPT" >"$LOG" 2>&1 &
traffic_pid=$!

for _ in $(seq 120); do
  phase=$(kc get pod "$traffic_pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = Running ] && break
  if [ "$phase" = Failed ] || [ "$phase" = Succeeded ]; then
    cat "$LOG" >&2
    echo "k6 exited before the slow-start drill began" >&2
    exit 1
  fi
  sleep 1
done
[ "${phase:-}" = Running ] || { echo "k6 did not start" >&2; exit 1; }

patch=$(python3 -c 'import json; print(json.dumps([{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"STARTUP_DELAY_SECONDS","value":"60"}}]))')
kc patch rollout api --type=json --patch "$patch"
changed=1
kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout="$ROLLOUT_TIMEOUT"
restarts=$(kc get pods -l app.kubernetes.io/name=api -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' | awk '{total=0; for (i=1; i<=NF; i++) total += $i; print total+0}')
kc get pods -l app.kubernetes.io/name=api -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
[ "$restarts" = 0 ] || { echo "FAIL: api container restart count is $restarts" >&2; exit 1; }

kubectl argo rollouts --context kind-orderlab -n "$NS" undo api
kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout="$ROLLOUT_TIMEOUT"
finished=1
wait "$traffic_pid" || { cat "$LOG" >&2; echo "k6 saw failed requests during slow start or restore" >&2; exit 1; }
traffic_pid=
cat "$LOG"
echo "PASS: 60-second startup completed with zero API container restarts"
