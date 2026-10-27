# Implemented starter scope

Source: the current Google Doc's **One continuous engineering project**, reviewed during implementation. The user requested local Python/Docker operation and assigned Kubernetes deployment to the trainee.

| Source requirement | Local implementation | Evidence command |
|---|---|---|
| Order-processing API and PostgreSQL | FastAPI service, durable pending/confirmed/rejected orders, independent payment ledger | `lab.py smoke`; integration tests |
| Controllable downstream stub | Python payment API; delay, transient failure, decline, response loss after commit | `lab.py fault payments ...`; response-loss tests |
| Tests and basic CI | HTTP/database integration, concurrency, migrations, gate tests; GitHub workflow | `lab.py test`; `.github/workflows/ci.yml` |
| Container packaging | Pinned Python base, locked packages, non-root/read-only app, Compose | `lab.py up`; container inspect |
| Load generation and evaluation | Standard-library workload and sample/comparability/error/latency gate | `load.py`; `gate.py`; `release.py` |
| Telemetry | Structured logs, Prometheus, Grafana dashboard, OTel→Jaeger traces | `verify.py` live checks |
| Backup/restore scripts | Consistent snapshot archive+manifest; isolated restored app; RTO/RPO report | `lab.py backup`; `lab.py restore`; `verify.py` |
| Fault-injection switches | Authenticated runtime controls and startup/pool/retry configuration | Fault tests; lab guide |
| Two isolated sandboxes | Separate Compose projects, networks, volumes, ports, local credentials | Staging startup, image/isolation checks |
| Seed data and load targets | HTTP seed command and deterministic request shape | `lab.py seed`; `load.py` |
| Tested lab guide and evidence | Four-week instructions, runbook, three ADRs, generated verification reports | `docs/labs.md`; `evidence/` |
| Schema change scaffold | Additive SQL, repeatable backfill, old-reader compatibility test | Migration integration test |
| Alert scaffold and scenarios | Actual Prometheus rules plus six promtool fixtures | `verify.py` |

The starter supplies a working system that trainees can investigate and improve. It does not pre-complete every student assignment in the four-week course. Cloud accounts/IAM/OIDC, signed registry attestations, protected remote deployment environments, remote Terraform backends/modules/drift exercises, Kubernetes manifests, canary routing, and production operations require the trainee's target environment. No external cloud resources, remote repositories, or deployments were created.

The local release helper is clearly labeled single-instance replacement. There is no pretend rolling-deployment, remote-state, or provenance implementation used to claim the local starter is complete.
