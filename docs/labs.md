# Four-week local lab guide

Use an otherwise idle environment for each drill. Run `python3 scripts/lab.py reset-faults` before and after. Save commands, observations, hypotheses, fixes, and retest results in `evidence/`. Record the image ID, workload, and relevant configuration with each experiment.

## Week 1 — Delivery and trust

1. Start the default lab, run the tests, and inspect the basic CI workflow. Map the source, build, image, runtime, and credential boundaries.
2. Start `.env.staging` using the README's separate project and ports. Compare API container image IDs; create an order in the primary environment and demonstrate it is absent from staging.
3. Run 1,000 requests to collect a healthy baseline. Evaluate a second sample with `scripts/gate.py`.
4. Run the release helper's `--inject-failure` drill. Its expected exit code is 1. Inspect `rolled_back`, the prior/current image IDs, and a successful transaction after recovery.
5. Complete the release decision record. In the trainee repository/platform, add signed provenance verification, scoped OIDC access, protected environments, and negative identity/artifact tests. The local image ID and Docker build metadata do not satisfy that exercise by themselves.

Evidence: test log, identical local image IDs, environment-isolation check, baseline, rejected release report, rollback transaction, trust-boundary decision. Hosted CI and cloud identity exercises require the trainee's own environment.

## Week 2 — Runtime and infrastructure

1. Observe `/health/live`, `/health/ready`, Docker health, and Prometheus targets. Enable `not_ready`; show liveness stays 200 while readiness is 503.
2. Enable a slow payment dependency; explain why the API's liveness should remain healthy. Compare request failures with the trace's dependency-attempt spans.
3. Enable API `db_hold_ms: 800`. Run 40 requests at concurrency 16. Inspect errors, latency, and `/admin/pool`. Reset and rerun the same workload. Explain pool wait versus CPU/memory pressure.
4. Change `DB_POOL_SIZE` or the dependency retry budget, recreate the API, repeat the workload, and evaluate effects. More concurrency is not automatically a fix for a slow downstream.
5. Under a modest load, restart the API, inspect shutdown logs, and distinguish drained in-flight work from requests arriving while the sole instance is unavailable. Record why this is not a zero-downtime deployment.

Trainee-owned target-platform extension: Terraform module/state/locking/drift work, replica health probes, resource limits, routing/draining, and rolling deployment. Compose supplies the local runtime and bounded process resources; it does not pretend to be a remote Terraform backend or Kubernetes cluster.

Evidence: same-load before/after measurements, pool statistics, a linked trace, shutdown observations, and runtime decision record.

## Week 3 — Schema and partial failure

1. Read migrations 001–003 and the compatibility test. On a fresh staging database, warm the old API under load, apply expansion, and repeat the old API tests:

   ```sh
   docker compose run --rm --no-deps migrate python scripts/migrate.py --through 002
   docker compose run --rm --no-deps migrate python scripts/migrate.py --through 003
   python3 scripts/lab.py test
   ```

2. Add the new application's explicit field contract and dual-version tests as a trainee change. Decide which new data is representable by the old application. Do not infer compatibility solely from a nullable column.
3. Set `payments.fail_next` to 3 and submit one order. Observe bounded failure and a `pending` row. Reset and repeat the same request/key: the original intent resumes.
4. Set `payments.timeout_after_commit_ms` to 900. Observe the first payment commit and lost response, then the retry returning the original payment. Repeat the same API key concurrently; the tests verify one order/payment.
5. Compare a healthy release to `api.fail_every: 5` or `api.latency_ms: 200` with at least 1,000 requests at the same concurrency. Explain why the gate rejects it. Define when to roll back, fix forward, or stop because data compatibility is uncertain.

Evidence: migration tests, data-contract decision, retry trace, database row counts, failing gate, and verified recovery. A canary requires a real traffic splitter; the supplied helper intentionally does not fake one.

## Week 4 — SLOs, incidents, and recovery

1. Explain eligible events, the 99.9% illustrative objective, and burn-rate calculation. Read the alert queries; distinguish bad service behavior, too little traffic, and absent telemetry.
2. Run the six real Prometheus rule fixtures:

   ```sh
   docker compose run --rm --no-deps -v "$PWD/observability:/rules:ro" \
     --entrypoint promtool prometheus test rules /rules/alerts.test.yml
   ```

3. Run `python3 scripts/verify.py`. Inspect the restore report: exact row hashes, successful restored read/write, a known post-backup order missing from the restored point, actual elapsed recovery, and snapshot age.
4. Mentor selects one unannounced fault from latency, bounded dependency failures, response loss, readiness, or connection-pool pressure. Give an impact/update within 10 minutes. Use logs, metrics, and traces; stabilize, verify recovery, and reset faults.
5. Write the incident review and defend a changed requirement: double traffic, shorter recovery time, a data-format incompatibility, or a much slower dependency. Identify what the local evidence does not prove.

Evidence: SLO reasoning, alert fixtures, restore report, incident timeline and status updates, preventive action with owner/retest condition, and completed handover.

## Mentor acceptance

Do not accept a happy-path screenshot as completion. Require the negative cases: a rejected release, an ambiguous write that does not duplicate effects, a real data restore, and an explanation of a failure using measured evidence. Course assessment standards remain in the Google Doc; this guide supplies the functioning local project and reproducible experiments.
