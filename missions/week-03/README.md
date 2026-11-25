# Week 3 Mission: Bottleneck Hunt (USE Method + k6)

Standalone Kubernetes exercise (`missions/week-03/`) running a tiny FastAPI + PostgreSQL app with three planted runtime bottlenecks (`seeded.py`) and their targeted fixes (`fixed.py`), measured inside kind with `k6` and container cgroup v2 USE signals (`/use`).

## Run

```sh
python3 missions/week-03/hunt.py seeded --out evidence/week3-mission/seeded.json
python3 missions/week-03/hunt.py fixed  --out evidence/week3-mission/fixed.json
kubectl --context kind-orderlab delete namespace bottleneck
```

## USE Method Diagnosis and Before/After Results

The commands above write raw JSON to the local, Git-ignored `evidence/week3-mission/` directory. Attach screenshots of the seeded/fixed summary values to the mission PR; do not add generated evidence files to Git.

| Bottleneck | Endpoint & load | USE signal (Seeded) | Before (`seeded`) | After (`fixed`) | Fix |
|---|---|---|---|---|---|
| **1. CPU throttling** | `GET /cpu`, 20 req/s, 60 s | **Saturation:** `cpu_throttled_ratio = 0.806` (80.6% of CFS periods throttled under `100m` limit) | p95 **6,731 ms**, errors **12.0%**, dropped **134** | p95 **8 ms**, errors **0%**, dropped **0**, throttled **0** | Raise `requests.cpu` to `500m` and remove the CPU limit (`overlays/fixed`) |
| **2. Memory leak** | `POST /remember`, 20 req/s, 90 s | **Errors:** `restarts = 1`, `last_termination = OOMKilled` under `128Mi` limit | `OOMKilled` restart, errors **2.03%**, dropped **127** | **0** restarts, errors **0%**, dropped **0**, end memory **61.3 MiB** | Replace unbounded list with `deque(maxlen=100)` (`fixed.py`) and set `memory request == limit: 192Mi` |
| **3. Small DB pool** | `GET /db`, 80 req/s, 60 s | **Saturation:** `pool_max = 1`, `pool_avg_wait_ms = 9,976 ms` | p95 **13,118 ms**, dropped **2,011** (2,789 / 4,800 reqs) | p95 **26 ms**, pool wait **4 ms**, errors **0%**, dropped **0** (4,800 / 4,800 reqs) | Size pool (`min_size=2, max_size=10`) for `80 req/s * 0.02 s = 1.6` avg in-flight + headroom, and fail fast with `503` on `PoolTimeout` (`timeout=1 s`) |
