#!/usr/bin/env bash
# Demonstrate one healthy update and one faulted update guarded by rollout-gate.sh.
set -euo pipefail

NS=${1:-orderlab-staging}
KUBECTL=(kubectl --context kind-orderlab -n "$NS")
kc() { "${KUBECTL[@]}" "$@"; }
gate=(scripts/rollout-gate.sh "$NS")

if kc get rollout api >/dev/null 2>&1; then
  healthy=(kubectl argo rollouts --context kind-orderlab -n "$NS" restart api)
  faulty=(kubectl --context kind-orderlab -n "$NS" patch rollout api --type=json \
    --patch='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"INITIAL_FAIL_EVERY","value":"5"}}]')
else
  healthy=(kubectl --context kind-orderlab -n "$NS" rollout restart deployment/api)
  faulty=(kubectl --context kind-orderlab -n "$NS" set env deployment/api INITIAL_FAIL_EVERY=5)
fi

echo "Demo 1/2: healthy update"
RATE=20 "${gate[@]}" "${healthy[@]}"

echo "Demo 2/2: injected 503 regression"
log=$(mktemp "${TMPDIR:-/tmp}/rollout-gate-demo.XXXXXX")
if RATE=20 "${gate[@]}" "${faulty[@]}" >"$log" 2>&1; then
  cat "$log"
  rm -f "$log"
  echo "FAIL: the gate accepted the injected failure" >&2
  exit 1
fi
cat "$log"
grep -q 'gate: FAIL' "$log"
grep -q 'gate: rolled back' "$log"
rm -f "$log"
echo "PASS: the gate rejected the bad update and restored the prior revision"
