#!/usr/bin/env bash
# Gated api release: measure a baseline, run the release command under live traffic, and roll the
# api back automatically if errors exceed 1% or p95 rises more than 20% over the baseline.
#   scripts/rollout-gate.sh <namespace> <release command...>
# The gate window (WINDOW s) covers the rollout plus a bake period; k6 aborts on the first breach.
set -uo pipefail
NS=$1; shift
RATE=${RATE:-20} WINDOW=${WINDOW:-150}
kc() { kubectl --context kind-orderlab -n "$NS" "$@"; }
if kc get rollout api >/dev/null 2>&1; then API_KIND=rollout; else API_KIND=deployment; fi
api_status() {
  if [ "$API_KIND" = rollout ]; then kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout="$1"; else kc rollout status deployment/api --timeout="$1"; fi
}
k6() { # <pod name> <duration> [p95 limit ms]; prints the JSON summary line
  kc delete pod "$1" --ignore-not-found >/dev/null
  kc run "$1" -i --restart=Never --image=grafana/k6:2.3.0 --env=BASE_URL=http://api:8000 --env=RATE="$RATE" \
    --env=DURATION="$2" --env=P95_LIMIT_MS="${3:-}" -- run --quiet - <platform/k8s/tests/gate.js 2>/dev/null | grep '^{'
  local status=${PIPESTATUS[0]}
  kc delete pod "$1" --ignore-not-found >/dev/null
  return "$status"
}

baseline=$(k6 gate-baseline 30s) || { echo "gate: baseline run failed; not releasing"; exit 1; }
read -r requests errors p95 < <(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); print(b["requests"], b["error_rate"], b["p95_ms"])' "$baseline")
# Never release on top of a sick or unmeasured baseline: the comparison would mean nothing.
python3 -c "import sys; sys.exit(0 if $requests >= 500 and $errors <= 0.01 else 1)" ||
  { echo "gate: unhealthy baseline $baseline; not releasing"; exit 1; }
limit=$(python3 -c "print(round($p95 * 1.2, 1))")
echo "gate: baseline p95=${p95}ms errors=${errors} over ${requests} requests -> limit p95<${limit}ms, errors<1%"

start=$(date +%s)
k6 gate "${WINDOW}s" "$limit" >"${TMPDIR:-/tmp}/gate-$NS.json" &
gate=$!
sleep 5 # traffic is flowing before anything changes
deploy_status=0
"$@" || deploy_status=$?
api_status "${WINDOW}s" >/dev/null 2>&1 &
rollout=$!

wait $gate; verdict=$?
result=$(cat "${TMPDIR:-/tmp}/gate-$NS.json")
if [ $verdict -eq 0 ]; then
  if wait $rollout; then
    if [ "$deploy_status" -eq 0 ]; then
      echo "gate: PASS $result"
      exit 0
    fi
    echo "gate: deploy command failed with exit code $deploy_status after a healthy rollout"
    exit "$deploy_status"
  fi
  echo "gate: rollout did not complete within ${WINDOW}s"
else
  kill $rollout 2>/dev/null
  wait "$rollout" 2>/dev/null || true
  echo "gate: FAIL $result"
fi
if [ "$API_KIND" = rollout ]; then
  kubectl argo rollouts --context kind-orderlab -n "$NS" abort api >/dev/null 2>&1 || true
  kubectl argo rollouts --context kind-orderlab -n "$NS" undo api
  kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout=120s
else
  kc rollout undo deployment/api
  kc rollout status deployment/api --timeout=120s
fi
echo "gate: rolled back; halted $(($(date +%s) - start))s after the release started"
exit 1
