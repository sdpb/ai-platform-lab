# ADR 003 — Durable intent, bounded retries, verified restoration

Status: starter decision, available for trainee review.

**Constraints:** a payment may commit before a response is lost; concurrent client retries occur; backup success alone does not prove recoverability.

**Decision:** persist request identity before the downstream side effect, serialize confirmation by order, deduplicate payments by order ID, retry transient failures at one layer, and preserve pending intents. Use exported-snapshot backups and restore into an isolated application with row-hash and business-operation checks.

**Alternatives:** retry with fresh IDs (duplicates effects), hold one distributed transaction (not available across HTTP), asynchronous outbox/reconciliation (more scalable but additional states), overwrite the original DB during a drill (destroys evidence).

**Consequences:** bounded synchronous implementation with demonstrable response-loss handling. Pending intents need caller retries; no autonomous recovery worker is included. RTO/RPO depend on measured backup age and restore duration, not configuration labels. Expand/backfill stays compatible; contraction requires a separate reviewed change.

**Evidence to attach:** response-loss tests, one-effect row counts, restore report, SLO fixtures, incident timeline. **Trainee decision:** what changes when throughput doubles, keys expire, or a tighter recovery target is required?
