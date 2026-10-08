# ADR 001 — Build once; evaluate replacement before acceptance

Status: starter decision, available for trainee review.

**Constraints:** local Docker, one application image, no registry or cluster prerequisite, reproducible failure demonstration.

**Decision:** build the Python image once, reuse its immutable local ID across environments, and gate a replacement using a comparable 1,000-request workload. Restore the previous ID and verify a transaction if the gate fails. Serialize releases per environment.

**Alternatives:** rebuild per environment (loses artifact identity), rolling replacement (requires multiple instances and routing), canary (also requires traffic allocation and sufficient observations).

**Consequences:** the reference works locally and makes release rejection observable, but replacement causes a service gap. Local identity is not signed provenance. Hosted attestations, OIDC, policy, and rolling deployment are trainee work.

**Evidence to attach:** baseline/candidate reports, rejected release report, recovered transaction, environment image IDs. **Trainee decision:** which deployment strategy fits the client constraints, and what proves an artifact is trusted?
