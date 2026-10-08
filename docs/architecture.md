# Architecture and operating limits

## Order lifecycle

1. Validate the request and require a caller-supplied idempotency key.
2. Insert a `pending` order and normalized request hash under a unique key; commit the intent before contacting the payment service.
3. In a new transaction, lock that one order. Reject a reused key with a different payload. Return an already terminal order without charging again.
4. Ask the payment stub to charge the persisted order ID. The stub commits its payment in an independent transaction with a unique `order_id`.
5. Retry transient transport/5xx/429 failures at one layer, with a bounded attempt budget and jitter. A timeout after payment commit is safe to retry against that same ID.
6. Commit `confirmed` with the payment ID, or `rejected` after a decline. An exhausted transient failure leaves a durable `pending` intent for a caller retry.

This is at-least-once request handling with idempotent business effects within the lab's database contracts. It is not a general exactly-once distributed transaction claim. Idempotency keys are retained indefinitely here; a production retention and replay policy would be required.

The stub durably records both accepted and rejected payment decisions under a per-order transaction lock. A previously accepted charge cannot become a decline when fault settings change, and a late in-flight request cannot charge an order after another request committed its rejection. The backup manifest verifies these decision rows alongside orders and successful payments.

## Transaction and capacity choices

The order row lock is held while awaiting the payment service. This keeps the reference implementation easy to inspect and serializes concurrent duplicates, but consumes a pool connection during a slow dependency call. The `db_hold_ms` fault magnifies this behavior for the capacity exercise. A more scalable design could use asynchronous processing, leases, an outbox, and reconciliation; those introduce additional failure modes and are trainee design alternatives.

PostgreSQL stores the order and payment ledgers in the same instance for local convenience, but their transactions commit independently. Shared DB credentials and a common database are lab simplifications, not a production trust boundary. Only synthetic data belongs here.

API database queries specify their result columns. This is intentional: adding a column can invalidate a prepared `SELECT *` result type. The migration test exercises old-reader compatibility while the expanded schema accepts an additional field. There is no destructive contraction script; trainees must define the compatibility window before removing old fields.

## Telemetry

- JSON logs: service, route, method, status, duration, request ID, trace ID. No request bodies, tokens, or database connection strings are logged by application code.
- Prometheus: HTTP count/latency, dependency attempts by outcome, committed-payment counter, standard process metrics. Histogram/count labels avoid order IDs and URLs with variable identifiers.
- Jaeger: server spans for both HTTP services, an order-confirmation span, a payment-commit span, and per-attempt dependency spans. W3C trace context crosses the HTTP dependency boundary.
- Grafana: a provisioned six-panel dashboard and Prometheus/Jaeger data sources. Logs stay in Docker; no log aggregation platform is installed.

The SLO example concerns valid `POST /orders` requests: 2xx are good events; 5xx are bad events. Validation/conflict 4xx are excluded from the SLO denominator but cause load-test gates to fail as unexpected workload behavior. A `rejected` payment order is a valid processed outcome, not an availability failure. The burn alert combines 1h and 5m error ratios at a 14.4× burn threshold for a 99.9% target, with a minimum 1,000-event sample. Low traffic and absent instrumentation have separate non-page signals. Notifications are not sent externally; inspect alert states in Prometheus.

Metrics and traces are not proofs of a 30-day SLO. Prometheus retains only 24 hours locally; Jaeger memory storage is intentionally ephemeral.

## Fault controls

Controls are in process memory and intentionally reset on restart. The default deployment uses one worker in each service. Multiple replicas would have independent fault settings; use deployment-level fault injection or a shared control mechanism when adapting this to Kubernetes. Admin endpoints use a generated local token and are loopback-exposed only through Compose. They must be removed or protected under the target platform's access controls before deployment elsewhere.

## Release and restore semantics

The local release helper stops/replaces one API container, evaluates a comparable workload, and restores the prior Docker image on failure. It is not rolling delivery and can interrupt traffic. Image IDs identify local content; they do not prove source identity. CI attestations, OIDC, environment rules, remote Terraform state, and Kubernetes deployment belong to the trainee's target environment.

Logical backups use an exported consistent snapshot shared by the verification query and `pg_dump`. Restore checks SHA-256 and all order/payment rows before starting a separate restored application. The timed interval includes local restore-service startup, archive restore, data checks, and an application transaction. The measured recovery point is the snapshot boundary; an idle database's old last-write timestamp does not imply actual loss. The report separately lists new source orders absent from the backup. Recovery does not overwrite the main environment.

This starter has no end-user authentication, TLS ingress, HA database, PITR/WAL archive, background reconciliation, payment refunds, multi-region recovery, or production scaling guarantees. These limits are explicit design inputs for the course.
