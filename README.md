# OrderLab — DevOps service-ownership project

A working Python order API, PostgreSQL database, and controllable payment service for the [four-week DevOps course](https://docs.google.com/document/d/1F0GCS7TsjeNFUCLOk9jZ-i1oruW5qbKSn_rIRidci9A/edit). It includes integration tests, Docker packaging, basic CI, load generation, metrics/traces, additive migration scaffolding, failure switches, and consistent backup/restore drills.

## Start locally

Prerequisites: Docker with Compose v2 and Python 3.9+ on the host. Application code runs on Python 3.12 inside Docker. No host Python packages are required. Allow about 4 GB of Docker memory for the default environment; running staging and recovery together needs more.

Run from this directory:

```sh
python3 scripts/lab.py init
python3 scripts/lab.py up
python3 scripts/lab.py seed
python3 scripts/lab.py smoke
```

`init` generates local credentials in `.env` and never overwrites an existing file. If this workspace is already initialized, begin with `up`. The first start downloads images; subsequent starts use cached layers. `up` builds the application **once** and uses that image for API, payment stub, tests, and migrations.

| Service | Local URL | Use |
|---|---|---|
| Orders API / Swagger | [localhost:8000/docs](http://localhost:8000/docs) | Interactive API and schemas |
| Payment stub / Swagger | [localhost:8001/docs](http://localhost:8001/docs) | Downstream contract and fault switches |
| Grafana dashboard | [localhost:3000/d/orderlab](http://localhost:3000/d/orderlab) | Latency, traffic, errors, dependencies, memory, alerts |
| Prometheus | [localhost:9090](http://localhost:9090) | Queries, targets, alert states |
| Jaeger | [localhost:16686](http://localhost:16686) | Distributed traces across both Python services |

Grafana login: `admin`; password: `GRAFANA_PASSWORD` in `.env`. Ports bind to loopback. PostgreSQL is reachable only inside the Compose network. Local fault endpoints require `X-Lab-Token`; the CLI reads it from `.env`. This is a synthetic-data lab, with no end-user authentication or real payment processing.

## Create an order

```sh
curl -i http://localhost:8000/orders \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: my-first-order' \
  -d '{"customer_id":"alice","sku":"widget","quantity":2,"unit_price_cents":1250}'
```

The response contains an order ID, integer-cent total, payment ID, and `confirmed` status. Repeat the same key and body: receive the original order (HTTP 200, `Idempotent-Replayed: true`). Reuse a key with a different body: HTTP 409. Read it at `GET /orders/{id}` or list recent orders at `GET /orders?limit=20`.

`X-Trace-ID` links the response to a Jaeger trace; structured Docker logs contain the same trace ID and a bounded request ID. Metrics use route templates, not order/customer IDs.

## Architecture

```text
client / load generator -> orders-api -> payments-stub
                             |                |
                             +--> PostgreSQL <-+
                             |                |
                             +-- OTLP traces --> Jaeger
Prometheus --scrapes--> both APIs --> Grafana queries Prometheus
backup archive --restore--> isolated restore-db + restore-api + restore-payments
```

The services use separate logical tables in one lab database. The payment transaction commits independently, so a payment can succeed while its HTTP response is lost. This gives the course a real ambiguous-outcome problem without adding a second database server. Production trust/isolation boundaries would differ.

The API commits a pending order intent, locks that order during confirmation, calls the idempotent downstream, then commits its final state. Both services use database uniqueness, not process memory, to prevent duplicate business effects. A bounded retry budget handles transient failures; permanent declines remain `rejected`. Pending operations can be resumed by repeating the original key and payload. No background reconciler is supplied.

`/health/live` checks process liveness. `/health/ready` checks PostgreSQL and the readiness switch; it does not restart the service because a payment dependency is down. One Uvicorn worker per container keeps lab fault controls deterministic. See [design decisions](docs/adr/001-release-strategy.md) and [known limitations](docs/architecture.md).

## Verify the working project

```sh
python3 scripts/lab.py test
python3 scripts/verify.py
```

`test` checks persistence, concurrent duplicates, payload conflicts, timeout after payment commit, lost API responses, retry exhaustion/recovery, declines, readiness, admin controls, migration compatibility, route labels, and release-gate logic. Run it against an idle lab: tests deliberately change fault settings and apply additive migrations.

`verify.py` runs lint, the integration/gate tests, six Prometheus alert scenarios, live trace/metric/dashboard checks, an API restart/persistence check, and an isolated restore with a known post-backup transaction. Evidence lands in `evidence/verification.json`, `evidence/restore.json`, and log files. It exits nonzero on a failed check. Recovery targets are 15 minutes RTO and 5 minutes snapshot-age RPO for this lab only.

## Faults and experiments

```sh
python3 scripts/lab.py fault payments '{"latency_ms":800}'
python3 scripts/lab.py fault payments '{"fail_next":3}'
python3 scripts/lab.py fault payments '{"timeout_after_commit_ms":900}'
python3 scripts/lab.py fault api '{"db_hold_ms":800}'
python3 scripts/lab.py fault api '{"fail_every":5}'
python3 scripts/lab.py fault api '{"response_delay_after_commit_ms":1500}'
python3 scripts/lab.py fault api '{"not_ready":true}'
python3 scripts/lab.py reset-faults
```

Each `fault` command replaces that service’s complete settings; omitted settings return to zero/false. Fault settings reset on process restart and are not shared across replicas. Swagger documents allowed ranges. `db_hold_ms` deliberately holds a pool connection to reproduce contention; use modest concurrency and reset afterward. `STARTUP_DELAY_SECONDS`, `DB_POOL_SIZE`, `DEPENDENCY_TIMEOUT`, and `DEPENDENCY_ATTEMPTS` are restart-time settings in `.env`.

## Load and local release gates

```sh
python3 scripts/lab.py reset-faults
python3 scripts/load.py --requests 1000 --concurrency 8 --output evidence/baseline.json
python3 scripts/lab.py fault api '{"fail_every":5}'
python3 scripts/load.py --requests 1000 --concurrency 8 --output evidence/regression.json
python3 scripts/gate.py evidence/baseline.json evidence/regression.json
python3 scripts/lab.py reset-faults
```

The gate intentionally exits 1 for a regression. It requires 1,000 measured samples, comparable concurrency/workload/warm-up, no unexpected 4xx, server/transport errors at most 1%, and p95 latency at most 20% above the baseline. Each run first sends 100 warm-up requests, excluded from its reported statistics. These thresholds are course examples. This is a closed-loop load test; increasing latency decreases offered throughput. Keep concurrency and hardware conditions comparable. Small local timing changes can legitimately reject a release; inspect the measurements rather than bypassing the gate.

For a real local container replacement and measured rollback:

```sh
python3 scripts/release.py --candidate orderlab:local --baseline evidence/baseline.json
python3 scripts/release.py --candidate orderlab:local --baseline evidence/baseline.json \
  --inject-failure --output evidence/release-rejected.json
```

The second command deliberately fails, exits 1, restores the previous image, and verifies a business transaction. A project-scoped lock prevents overlapping releases. Docker image IDs provide local immutable identity; they are **not** cryptographic provenance or registry manifest attestations. The local script replaces one instance and permits downtime. The trainee implements rolling/canary deployment and signed artifact/OIDC controls in their target platform. A later `lab.py up` re-applies the image configured in `.env`.

To test rejection of a genuinely different image, build the deliberately faulty example and use it as the candidate:

```sh
docker build -f examples/Dockerfile.regression -t orderlab:regression .
python3 scripts/release.py --candidate orderlab:regression --baseline evidence/baseline.json \
  --output evidence/release-regression.json
```

That image starts with `INITIAL_FAIL_EVERY=5`. It stays healthy at the process/readiness level but fails one in five business operations. The gate must reject it and restore the different previous image ID.

## A second isolated local environment

```sh
python3 scripts/lab.py --env-file .env.staging init --name orderlab-staging --offset 1000
python3 scripts/lab.py --env-file .env.staging up --no-build
python3 scripts/lab.py --env-file .env.staging smoke
```

Staging uses port 9000 for the API, 9001 for the stub, 4000 for Grafana, 10090 for Prometheus, and 17686 for Jaeger. It has independent networks, volumes, credentials, and data. `--no-build` reuses the same local application image. Use `--env-file .env.staging` before the operation on every `lab.py` command. The load tool accepts `--url http://localhost:9000`.

## Backup and restore

```sh
python3 scripts/lab.py backup
python3 scripts/lab.py restore backups/<archive-name>.dump
```

Use the actual archive path printed by `backup`. An exported PostgreSQL snapshot keeps the dump and row-level verification manifest consistent even if requests are in flight. The manifest includes archive SHA-256, row counts/hashes, snapshot time, and order IDs. Archives contain synthetic application data and stay out of Git.

Restore replaces **only** the disposable `restore-db` database, never the main database. It starts an isolated application on [localhost:8100/docs](http://localhost:8100/docs), compares all restored order/payment rows, reads an existing order, and creates/reads a new one. `evidence/restore.json` records actual elapsed recovery time, snapshot age, newest restored transaction, known new orders absent from the backup, and whether targets were met. An old backup may restore correctly but fail the RPO gate. This is a logical full-backup drill, not point-in-time recovery or multi-region DR.

## Training and CI

- [Four-week lab guide](docs/labs.md): experiments, expected evidence, and trainee-owned extensions.
- [Runbook](docs/runbook.md): diagnosis, recovery, and escalation.
- [Architecture and limits](docs/architecture.md): transaction boundaries and operational trade-offs.
- [Decision record templates](docs/adr/001-release-strategy.md): release, runtime/IaC, and recovery.
- [Completion scope](docs/scope.md): what the starter supplies and what trainees implement.
- [Local verification report](docs/verification.md): observed results and links to the captured evidence.

`.github/workflows/ci.yml` runs the Docker-based checks and restore drill when this directory is used as the root of its own GitHub repository. It is supplied locally; no remote repository or hosted CI execution is implied. Cloud IAM, OIDC, Terraform backend provisioning, and Kubernetes manifests are trainee/environment-specific work. No Kubernetes deployment is included.

## Stop and clean up

```sh
python3 scripts/lab.py down
python3 scripts/lab.py --env-file .env.staging down
```

These keep named database volumes. For a deliberate complete lab reset, `docker compose --profile recovery down -v` removes this environment’s data volumes; backups remain on disk. Only run it when you intend to delete the lab data. Docker log rotation and 24-hour Prometheus retention bound common local storage growth; Jaeger uses its default in-memory store, so traces are ephemeral.
