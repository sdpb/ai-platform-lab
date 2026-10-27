# Local verification report

Verified at 2026-09-15T15:23:36.491500+00:00 on Docker Desktop, Linux ARM64 containers.

## Result

The main OrderLab environment is running locally. Its API is live and ready, and a final order was created and read successfully. All fault controls were reset. Staging and restored-environment containers were stopped after validation to reduce resource usage; their data volumes and configurations remain available.

Application image: `sha256:768bddd1e268003e3e838a40dc80f6c8e4028ad393992502690ebef092f5795c`. SHA-256 comparisons confirmed that all 13 Python source/script/test files in the running API container match this directory.

## Evidence

These results describe the original local verification run. Generated logs and reports are excluded from Git; the paths below are local outputs that the documented verification commands recreate.

| Requirement | Observed result | Evidence |
|---|---|---|
| Application, persistence, retries, concurrency, migrations, gates | 17 tests passed in main and 17 on a fresh staging database | `evidence/tests.log`, `evidence/staging-tests.log` |
| Alerts | Six actual Prometheus scenarios passed: healthy, sustained errors, short spike, low traffic, failed scrape, absent request instrumentation | `evidence/alerts.log` |
| Telemetry | Trace contains orders-api and payments-stub; both scrape targets healthy; Grafana has six provisioned panels | `evidence/verification.json` |
| Restart durability | Previously created order remains confirmed after API restart | `evidence/verification.json` |
| Two environments | Identical immutable application image, distinct credentials, bidirectional data isolation | `evidence/environments.json` |
| Load generation | 1000 measured requests after 100 warm-up requests; 0% errors; 482.497 req/s; p95 26.518 ms | `evidence/baseline.json` |
| Healthy release | Candidate passed sample/comparability/error/latency gates | `evidence/release-accepted.json` |
| Faulty artifact | Different image produced 20% errors; gate rejected it; prior image restored and a business operation verified | `evidence/release-regression.json` |
| Pool pressure | Injected hold increased p95 to 2024.907 ms and errors to 50%; reset restored p95 to 38.442 ms with no errors | `evidence/capacity.json` |
| Data restore | Orders, successful payments, and payment decisions matched snapshot fingerprints; restored API read/write passed | `evidence/restore.json` |
| Recovery objectives | 15.511 s recovery; 0.256 s snapshot age; one known post-backup order correctly absent; targets met | `evidence/restore.json` |
| Final running state | Live/ready, faults reset, actual container image and source verified | `evidence/final-runtime.json` |

The workload figures are observations from this laptop and closed-loop synthetic traffic, not production capacity guarantees. A prior healthy-image test was rejected when cold-start timing was compared to a warm baseline; both workloads now use the same explicit warm-up policy. Rolling SLO windows retain intentionally injected errors until those windows expire.

## Reproduce

From the project directory, run `python3 scripts/lab.py up`, then `python3 scripts/verify.py`. The README covers staging, faults, loads, releases, and restoration. To test the faulty artifact, build `examples/Dockerfile.regression` and run the release command; rejection is the expected nonzero exit.

The GitHub workflow is supplied and its checkout revision was verified against the official repository. Its constituent commands were run locally; hosted GitHub CI, signed attestations, OIDC, remote Terraform, and Kubernetes deployment were not executed. Those are trainee/environment-specific extensions, as recorded in [scope](scope.md).
