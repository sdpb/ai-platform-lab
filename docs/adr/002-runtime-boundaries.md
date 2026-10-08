# ADR 002 — Compose owns the local runtime

Status: starter decision, available for trainee review.

**Constraints:** portable Python/Docker starter, isolated synthetic data, bounded setup time, no cluster administration.

**Decision:** one Compose project per environment; separate networks/volumes/credentials; loopback ports; an unprivileged, read-only Python image; configurable connection-pool/retry limits. The API and payment ledger use independent transactions on one PostgreSQL instance.

**Alternatives:** shared staging DB (weaker isolation), per-service DB servers (more faithful but heavier), Kubernetes/Terraform-provisioned cloud (requires environment-specific access and infrastructure).

**Consequences:** easy local reproduction; no production HA or security-boundary claim. Row locks held during downstream calls provide a concrete capacity trade-off. Runtime flags, faults, and metrics allow before/after experiments. Target-platform Terraform state/locking and Kubernetes operation remain explicit trainee responsibilities.

**Evidence to attach:** isolation test, resource/pool statistics, same-load comparison, shutdown trace. **Trainee decision:** what belongs in an application module versus shared platform infrastructure, and how is drift reviewed?
