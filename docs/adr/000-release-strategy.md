# ADR-000 — Build once; evaluate replacement before acceptance

Status: accepted (Week 1, before the 10-week plan numbering)

**Constraints:** Amazon ECR for artifacts, AWS IAM OIDC for identity, separate build and deployment boundaries, reproducible failure demonstration.

**Decision:**

- **Workflows:** The CI pipeline is explicitly split into `pr.yml` and `release.yml` using a shared `test.yml`. This guarantees untrusted pull requests can never execute within a deployment environment or access AWS credentials.
- **Artifacts:** Build the Python image once, push it to Amazon ECR, and deploy the immutable digest across environments.
- **Identity:** Utilize AWS IAM roles via GitHub Actions OIDC federation. Separate roles are provisioned for CI (`AWS_BUILD_OIDC_ROLE_ARN`) and CD (`AWS_DEPLOY_OIDC_ROLE_ARN`, one per GitHub Environment) to strictly scope permissions; Terraform creates them (see [ADR-001](001-iac-and-environment-strategy.md)).
- **Provenance:** Generate build attestations using `actions/attest-build-provenance` against the ECR image digest, and verify it prior to running deployments.
- **Scanning and SBOM:** Trivy gates the pushed digest (CRITICAL/HIGH), and a CycloneDX SBOM is attested for the same digest; deploy jobs verify both attestations.

**Alternatives:** local image IDs (loses cross-environment persistence and signed provenance), single shared AWS credential (violates principle of least privilege), monolithic workflow (risks exposing secrets to untrusted PRs).

**Consequences:** The pipeline now strictly separates untrusted code (PRs) from deployment environments. Artifacts are cryptographically signed and stored in a remote registry (ECR). The rollout still uses local instance replacement (to be upgraded to rolling deployment in later weeks).

**Evidence to attach:** baseline/candidate reports, rejected release report, recovered transaction, ECR image URIs, successful attestation checks.
