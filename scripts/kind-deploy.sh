#!/usr/bin/env bash
# Deploy OrderLab to the local kind cluster. Used by `make k8s-deploy` and by the release pipeline.
#   scripts/kind-deploy.sh <staging|production> [registry/repo@sha256:digest]
# With an image, the kind nodes pull that exact digest from ECR (no rebuild, no retag).
# SECRET_ID=<env>/orderlab-secrets reads app secrets from AWS Secrets Manager; otherwise from .env.
set -euo pipefail
ENV=$1 IMAGE=${2:-}
NS=orderlab-$ENV
kc() { kubectl --context kind-orderlab "$@"; }

kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f -

# Secret values travel through stdin only, never argv.
if [ -n "${SECRET_ID:-}" ]; then
  aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text |
    python3 -c 'import json, sys; [print(f"{k}={v}") for k, v in json.load(sys.stdin).items() if k in ("POSTGRES_PASSWORD", "LAB_ADMIN_TOKEN")]'
else
  grep -E '^(POSTGRES_PASSWORD|LAB_ADMIN_TOKEN)=' .env
fi | kc -n "$NS" create secret generic orderlab-secrets --from-env-file=/dev/stdin --dry-run=client -o yaml | kc apply -f -

if [ -n "$IMAGE" ]; then
  # shortcut: the ECR token expires after 12 h; every deploy refreshes it, and pulled digests stay cached on the nodes.
  aws ecr get-login-password | python3 -c '
import base64, json, sys
b64 = lambda s: base64.b64encode(s.encode()).decode()
auth = {"auths": {sys.argv[1]: {"auth": b64("AWS:" + sys.stdin.read().strip())}}}
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockerconfigjson",
                  "metadata": {"name": "ecr-pull"}, "data": {".dockerconfigjson": b64(json.dumps(auth))}}))' "${IMAGE%%/*}" |
    kc -n "$NS" apply -f -
  until kc -n "$NS" get serviceaccount default >/dev/null 2>&1; do sleep 1; done
  kc -n "$NS" patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ecr-pull"}]}'
  # Wrapper overlay pins the digest; it lives in the checkout so the relative base path resolves.
  dir=$(mktemp -d "$PWD/.deploy.XXXXXX")
  trap 'rm -rf "$dir"' EXIT
  cat >"$dir/kustomization.yaml" <<EOF
resources: [../platform/k8s/overlays/$ENV]
images: [{name: orderlab, newName: ${IMAGE%@*}, digest: ${IMAGE#*@}}]
EOF
  kc apply -k "$dir"
else
  kc apply -k "platform/k8s/overlays/$ENV"
fi

kc -n "$NS" rollout status statefulset/postgres --timeout=180s
kc -n "$NS" rollout status deployment/payments --timeout=180s
if [ "${WAIT:-1}" = "1" ]; then
  if kc -n "$NS" get rollout api >/dev/null 2>&1; then
    kubectl argo rollouts --context kind-orderlab -n "$NS" status api --timeout=300s
    # The Rollout is ready before the old Deployment is removed during the one-time migration.
    kc -n "$NS" delete deployment/api --ignore-not-found
    kc -n "$NS" get rollout api -o jsonpath='deployed {.spec.template.spec.containers[0].image}{"\n"}'
  else
    kc -n "$NS" rollout status deployment/api --timeout=300s
    kc -n "$NS" get deployment api -o jsonpath='deployed {.spec.template.spec.containers[0].image}{"\n"}'
  fi
fi
