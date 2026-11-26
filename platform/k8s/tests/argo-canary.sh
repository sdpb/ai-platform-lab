#!/usr/bin/env bash
# Exercise healthy promotion and AnalysisTemplate aborts while k6 sends Service traffic.
set -euo pipefail

NS=${1:-orderlab-staging}
K6_IMAGE=${K6_IMAGE:-grafana/k6:2.3.0}
LOAD_SCRIPT=platform/k8s/tests/orders-load.js
kc() { kubectl --context kind-orderlab -n "$NS" "$@"; }

kc get rollout api >/dev/null
kubectl argo rollouts version | grep -Fq 'v1.10.2'
if ! kubectl --context kind-orderlab -n monitoring get deployment prometheus >/dev/null 2>&1; then
  echo "Prometheus is not installed; run make k8s-cluster first" >&2
  exit 1
fi

traffic_pid=
traffic_pod=
cleanup() {
  if [ -n "$traffic_pid" ]; then kill "$traffic_pid" 2>/dev/null || true; fi
  if [ -n "$traffic_pod" ]; then kc delete pod "$traffic_pod" --ignore-not-found >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM

start_traffic() {
  traffic_pod=$1
  kc delete pod "$traffic_pod" --ignore-not-found >/dev/null
  kc run "$traffic_pod" -i --restart=Never --image="$K6_IMAGE" \
    --env=BASE_URL=http://api:8000 --env=RATE=20 --env=DURATION=180s \
    -- run --quiet - <"$LOAD_SCRIPT" >"${TMPDIR:-/tmp}/$traffic_pod.log" 2>&1 &
  traffic_pid=$!
  for _ in $(seq 120); do
    phase=$(kc get pod "$traffic_pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = Running ] && return 0
    if [ "$phase" = Failed ] || [ "$phase" = Succeeded ]; then
      cat "${TMPDIR:-/tmp}/$traffic_pod.log" >&2
      echo "k6 pod exited before canary traffic started" >&2
      return 1
    fi
    sleep 1
  done
  echo "k6 pod did not become ready" >&2
  return 1
}

stop_traffic() {
  if [ -n "$traffic_pid" ]; then wait "$traffic_pid" || true; fi
  [ -z "$traffic_pod" ] || kc delete pod "$traffic_pod" --ignore-not-found >/dev/null
  traffic_pid=
  traffic_pod=
}

patch_candidate() {
  local mode=$1 marker=$2 patch
  patch=$(python3 - "$mode" "$marker" <<'PY'
import json
import sys

mode, marker = sys.argv[1:]
ops = [{"op": "add", "path": "/spec/template/metadata/annotations/canary-test", "value": marker}]
if mode == "errors":
    ops.append({"op": "add", "path": "/spec/template/spec/containers/0/env/-",
                "value": {"name": "INITIAL_FAIL_EVERY", "value": "5"}})
elif mode == "latency":
    ops.append({"op": "add", "path": "/spec/template/spec/containers/0/env/-",
                "value": {"name": "INITIAL_LATENCY_MS", "value": "500"}})
print(json.dumps(ops))
PY
)
  kc patch rollout api --type=json --patch "$patch"
}

healthy_canary() {
  local marker="healthy-$(date +%s)"
  echo "Starting healthy canary; analysis compares latest to stable at 20 req/s"
  start_traffic canary-healthy
  patch_candidate healthy "$marker"
  kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout=240s
  stop_traffic
  echo "PASS: healthy canary promoted"
}

failing_canary() {
  local mode=$1 marker="${1}-$(date +%s)" aborted=
  echo "Starting $mode canary; AnalysisTemplate must abort it"
  start_traffic "canary-$mode"
  patch_candidate "$mode" "$marker"
  for _ in $(seq 120); do
    aborted=$(kc get rollout api -o jsonpath='{.status.abort}' 2>/dev/null || true)
    [ "$aborted" = true ] && break
    sleep 2
  done
  stop_traffic
  if [ "$aborted" != true ]; then
    echo "FAIL: Argo did not abort the $mode canary" >&2
    kubectl argo rollouts --context kind-orderlab -n "$NS" abort api >/dev/null 2>&1 || true
    kubectl argo rollouts --context kind-orderlab -n "$NS" undo api >/dev/null 2>&1 || true
    exit 1
  fi
  echo "PASS: Argo aborted the $mode canary"
  kubectl argo rollouts --context kind-orderlab -n "$NS" undo api
  kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout=240s
  echo "PASS: stable revision restored after $mode canary"
}

healthy_canary
failing_canary errors
failing_canary latency
