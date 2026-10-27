# ADR 002 — Terraform remote state, environment isolation, and IaC design

Status: accepted

**Constraints:** Separate blast radius between environments; no long-lived AWS credentials; Terraform state must be encrypted and locked; secrets must not land in state as plaintext; new bootstrap resources cannot depend on remote state they are creating.

---

## Decision

### 1. Bootstrap-first provisioning

A dedicated `bootstrap/` stack provisions the state backend itself (S3 bucket + DynamoDB table). It uses a **local state** initially (the only safe choice when the remote backend doesn't exist yet). After applying, all other stacks switch to the remote S3 backend. This is a one-time, one-person operation.

**Alternatives considered:**
- Terraform Cloud: avoids the chicken-and-egg problem but adds a mandatory SaaS dependency outside the AWS-only scope of this lab.
- Manually creating S3 via the console: breaks the "everything in IaC" requirement and produces un-tracked resources.

### 2. Separate state per environment (blast radius minimization)

Three isolated remote state files:
- `shared/terraform.tfstate` — ECR repository and the one CI build IAM role.
- `staging/terraform.tfstate` — Staging secrets and CD deploy role scoped to the `staging` GitHub Environment.
- `production/terraform.tfstate` — Production secrets and CD deploy role scoped to the `production` GitHub Environment.

A state lock acquisition or corruption in `staging` cannot affect `production`. Rolling back production state never touches staging resources.

**Alternative considered:** One shared state file. Rejected because a destructive change to any resource (e.g. the ECR repo) would require access to all environments simultaneously, and a bad `terraform apply` in staging could destroy production IAM roles.

### 3. S3 native locking (Terraform ≥ 1.10) with DynamoDB fallback

`use_lockfile = true` is set on all environment backends. A DynamoDB table is also provisioned during bootstrap with `hash_key = "LockID"` for dual-mode compatibility and defense-in-depth.

**Why both:** The DynamoDB table is free under Pay-Per-Request and costs nothing extra. It protects teams that downgrade or use tools that do not support native S3 locking.

### 4. Secrets in AWS Secrets Manager — never in state

The `modules/secrets` module uses `aws_secretsmanager_secret_version` to store credentials. The `random_password` resources that generate values **do** appear in state (unavoidably), but the module is designed so that:
- All `sensitive = true` markings are applied on outputs.
- The state file itself is KMS-encrypted at rest (bucket SSE with CMK).
- No secret value is written to any `.tfvars` file committed to Git.

**Consequence:** A `terraform state pull` will expose the random_password result. This is a known Terraform limitation documented in the [sensitive data in state](https://developer.hashicorp.com/terraform/language/state/sensitive-data) docs. Mitigation: KMS encryption on state bucket + strict S3 bucket policy, and the Mission for Week 2 demonstrates the exploit and fix using ephemeral values.

### 5. IAM role separation: build vs. deploy

| Role | Trust | Permissions |
|------|-------|-------------|
| `ci_build` (shared) | Any ref in the repo (`repo:<org>/<repo>:*`) | `ecr:PutImage`, `ecr:InitiateLayerUpload`, etc. |
| `cd_deploy` (per env) | Strictly `repo:<org>/<repo>:environment:<env>` | `ecr:BatchGetImage`, `secretsmanager:GetSecretValue` for that env only |

The build role cannot access secrets. The deploy role cannot push images. An unauthorized workflow branch cannot assume the deploy role because its OIDC `sub` claim does not match the `environment:` suffix.

**Evidence to attach:** `terraform plan` output showing clean plan; IAM credential report confirming 0 access keys; `oidc:sub` condition in role trust policies.

---

## Consequences

- The bootstrap must be applied manually once, out of band of CI, before CI can run against remote state.
- Adding a new environment (e.g. `canary`) requires a new directory under `environments/` and a new state key — no module changes needed.
- Secret rotation requires a `terraform apply` to create a new `aws_secretsmanager_secret_version`; the old version is retained by AWS until explicitly deleted.
