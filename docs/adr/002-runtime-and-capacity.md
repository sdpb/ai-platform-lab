# ADR-002 — Kubernetes runtime boundaries and capacity

Status: accepted (Week 3)

**Constraints:** zero dropped requests during rolling restarts; tolerate a 60 s slow startup without a restart loop; isolate API availability from downstream `payments` outages; keep staging and production isolated on a shared 3-node kind cluster (`1` control plane, `2` workers); size capacity without exhausting PostgreSQL connections.

---

## Decision

### 1. Three-probe separation (`startupProbe`, `readinessProbe`, `livenessProbe`)

- `startupProbe` hits `/health/live` every `5 s` with `failureThreshold: 36` (`180 s` startup budget). Liveness and readiness probes stay paused until startup passes, eliminating the `4`-restart loop observed under `STARTUP_DELAY_SECONDS=60`.
- `readinessProbe` hits `/health/ready` (`SELECT 1` against PostgreSQL only) every `5 s`. A `payments` outage never pulls API pods out of Service endpoints, because restarting or delisting healthy API pods cannot heal a downstream outage.
- `livenessProbe` hits `/health/live` (event loop check only) every `10 s`.

**Alternative:** pointing liveness at `/health/ready` or omitting `startupProbe` — rejected because slow startups (`4` restarts) or transient DB/downstream blips trigger cascading pod restarts.

### 2. Graceful shutdown and pod spread

- The API Deployment uses `maxSurge: 1`, `maxUnavailable: 0` to add a ready pod before terminating an old one.
- `PodDisruptionBudget` (`minAvailable: 1`) + `topologySpreadConstraints` (`kubernetes.io/hostname`, `matchLabelKeys: [pod-template-hash]`) spread API pods across both worker nodes.
- `lifecycle.preStop` sleeps `10 s` so `kube-proxy` removes the pod from Service endpoints before `SIGTERM` reaches Uvicorn (`--timeout-graceful-shutdown 20`, inside `terminationGracePeriodSeconds: 40`). Under `20 req/s` in-cluster k6 load, failures dropped from `3 / 1801` (`0.16%`) to `0 / 1800` (`0.00%`).

**Alternative:** relying on `SIGTERM` alone — rejected because endpoint removal is asynchronous with `SIGTERM` delivery, causing `connection refused` / `i/o timeout` errors during endpoint propagation.

### 3. Resource sizing and namespace guardrails

- `api` requests `cpu: 100m`, `memory: 384Mi` with **no CPU limit** and `limits.memory == requests.memory` (`384Mi`, Guaranteed memory QoS). An emptyDir `/tmp` mount is capped at `sizeLimit: 64Mi`.
- Removing CPU limits prevents avoidable CFS throttling on CPU-bound spikes while `requests.cpu` still guarantees the pod's fair share under contention (proven in the Week 3 bottleneck hunt).
- `LimitRange` sets container defaults (`100m` CPU, `256Mi` memory) and `ResourceQuota` caps each environment namespace (`2` CPU requests, `4Gi` memory, `15` pods, `2` PVCs) so staging and production cannot starve each other.

**Alternative:** setting a tight CPU limit (`100m` or `200m`) — rejected because idle host CPU goes unused and bursts suffer CFS quota stalls; revisit only if noisy-neighbor isolation on multi-tenant nodes requires hard ceilings.

### 4. Horizontal Pod Autoscaler (`minReplicas: 2`, `maxReplicas: 6`, 70% CPU)

- `HorizontalPodAutoscaler` (`autoscaling/v2`) targets `Deployment/api` at `70%` average CPU utilization (`70m` per pod against the `100m` request), scaling `minReplicas: 2` to `maxReplicas: 6` (`scaleUp` stabilization `0 s`, up to `+100% / 15 s`; `scaleDown` stabilization `300 s`, `-1 pod / 60 s`).
- The Week 3 Deployment omits `spec.replicas` so the HPA manages its count. After converting to a Rollout, the manifest seeds `spec.replicas: 2` because Argo's scale subresource requires the field to exist; this bootstrap matches `minReplicas`, and the HPA changes it as load requires.

**Before vs. after (`platform/k8s/tests/capacity.sh` on `orderlab-staging`):**

| Rate (req/s) | Before (fixed 2) p95 / p99 | Before dropped | After (HPA) replicas | After (HPA) p95 / p99 | After dropped |
|---:|---|---:|---:|---|---:|
| 25 | 13.35 ms / 44.33 ms | 0 | 2 | 14.58 ms / 48.01 ms | 0 |
| 50 | 9.21 ms / 22.76 ms | 0 | 2 | 9.00 ms / 16.05 ms | 0 |
| 75 | 6.77 ms / 12.29 ms | 0 | 3 | 6.95 ms / 9.22 ms | 0 |
| 100 | 6.12 ms / 25.97 ms | 0 | 4 | 5.20 ms / 7.15 ms | 0 |
| 150 | 98.62 ms / 315.03 ms | 62 | 6 | **6.75 ms / 29.38 ms** | **0** |

---

## Consequences

- `metrics-server` (`platform/k8s/cluster/`) must be installed once per cluster before HPA can evaluate CPU utilization (`make k8s-cluster` applies it automatically).
- `ResourceQuota` (`2` CPU requests, `4Gi` memory, `15` pods) bounds `maxReplicas: 6` (`6 * 100m + payments 100m + postgres 100m = 800m` CPU; `6 * 384Mi + 384Mi + 512Mi = 3200Mi < 4Gi`). Raising `maxReplicas` requires raising both the namespace `ResourceQuota` and PostgreSQL `max_connections` (or introducing PgBouncer).

**Measured evidence:** probe and shutdown checks report zero restarts and zero failed requests during pod replacement; at 150 req/s, HPA scales to 6 replicas and reduces p95 from 98.62 ms with 62 dropped iterations to 6.75 ms with none. Screenshots of the local run output are attached to the capstone PR; generated evidence files stay out of Git.
