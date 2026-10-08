# OrderLab operational runbook

## Establish impact and preserve evidence

1. Record start time, environment, changed image/configuration, affected endpoint, and whether data correctness may be affected.
2. Check `python3 scripts/lab.py status`, `/health/live`, and `/health/ready`.
3. Inspect `docker compose logs --since 10m api payments`. Use the response's `X-Trace-ID` to locate the same request in Jaeger.
4. Open the Grafana dashboard: compare traffic, p95, error ratio, and dependency attempts. Inspect Prometheus targets before concluding missing metrics mean zero errors.
5. Send a short exercise update: impact, evidence so far, current mitigation, next update time. Avoid claiming a cause before testing it.

## Common cases

| Symptom | Discriminating evidence | Local action |
|---|---|---|
| Repeated 503 and many dependency attempts | Stub fault settings, client spans/outcomes | Fix dependency/fault; repeat the original key to resume pending orders |
| High latency plus pool acquisition failures | `/admin/pool`, `db_hold_ms`, trace time in confirmation | Remove the hold/slow call, lower offered concurrency, retest before resizing |
| Liveness healthy, readiness 503 | Readiness fault or actual database connectivity | Correct fault/DB; don't restart healthy processes to mask a dependency failure |
| High errors immediately after release | Compare image/version and before/after load | Evaluate compatibility, revert the previous image, verify a business operation |
| Caller timed out but DB shows confirmed | Same-key replay, unique payment count | Retry the same key and unchanged payload, never invent a new operation key |
| No metrics or very low traffic | Scrape status, absent/low-traffic alerts | Treat SLO as unknown; repair telemetry or gather a valid sample |

Fault inspection uses the generated token. The CLI can reset both services safely: `python3 scripts/lab.py reset-faults`. It will not repair an actual stopped database; start that service and wait for readiness if the mentor stopped it.

## Recovery verification

- Re-read the affected order and check its payment relationship.
- Confirm the expected image/version is running.
- Run a fresh business operation and a same-key replay.
- Verify latency/error behavior under comparable load.
- For data recovery, use `lab.py backup` and `lab.py restore <archive>`; inspect hashes and measured targets, not merely the presence of a dump file.

Do not drop/recreate the main volume as an incident shortcut. The restore drill has a separate target and port specifically to preserve source evidence.

## Escalation and incident review

Escalate to the mentor if the rollback crosses a schema/data compatibility boundary, the payment/order relationship cannot be explained, or repeated intervention risks losing evidence. Handover must identify the current owner, next update, current state, and remaining uncertainty.

Review template: impact; timeline; detection; mitigation; contributing conditions; recovery evidence; what was difficult; one preventive change; owner; verification condition. Be specific about local-only assumptions and avoid attributing system failures to individual blame.
