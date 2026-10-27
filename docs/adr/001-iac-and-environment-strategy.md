# ADR-001 — IaC and environment strategy

Status: accepted (Week 2)

**Constraints:** separate blast radius between environments; no long-lived AWS credentials; Terraform state encrypted and locked; secrets never in state or plan files; the state backend cannot depend on the remote state it creates; the whole stack must be cheap to destroy and rebuild (this is a training account).

---

## Decision

### 1. Bootstrap first, with local admin

`platform/terraform/bootstrap/` creates the state bucket (versioned, KMS-encrypted, public access blocked) and a DynamoDB lock table, using **local state** and an admin login. That login is also used for the first apply of `shared`, `staging` and `production`. After that, changes go through CI (section 6).

The bucket uses `force_destroy = true` and no `prevent_destroy`, and the secrets use `recovery_window_in_days = 0`. That is deliberate: the account is rebuilt often. A real production account would flip all three.

**Alternatives:** Terraform Cloud (extra SaaS outside the AWS-only scope); creating the bucket by hand (untracked resource).

### 2. One state per environment

| State | Contents |
|---|---|
| `shared/terraform.tfstate` | ECR repository, GitHub OIDC provider, CI build role |
| `staging/terraform.tfstate` | Staging secret, CD deploy role (`environment:staging`), runtime role |
| `production/terraform.tfstate` | Production secret, CD deploy role (`environment:production`), runtime role |

A lock or a broken apply in staging cannot touch production. Staging and production find the OIDC provider and ECR repository by name (data sources), so no ARNs are copied between stacks and they must be applied after `shared`.

**Alternative:** one state file — rejected because every change would need access to every environment at once.

### 3. Native S3 locking

`use_lockfile = true` on every backend (Terraform ≥ 1.10). The DynamoDB table stays available for older tooling but is not configured by default.

### 4. Secrets never in state

`modules/secrets` generates credentials with `ephemeral "random_password"` and writes them with the write-only `secret_string_wo`. Neither value is stored in state or in plan files; a test asserts `secret_string` stays null. Terraform cannot diff a value it never stored, so rotation is explicit: bump `secret_version`. This is the Week 2 mission's fix ([missions/week-02](../../missions/week-02/README.md)) applied to the platform.

### 5. Separate IAM roles, all created by Terraform

| Role | Stack | OIDC `sub` trust | Permissions | GitHub secret |
|---|---|---|---|---|
| `orderlab-ci-build-shared-role` | shared | `<prefix>:ref:refs/heads/main` | push to the one ECR repo | `AWS_BUILD_OIDC_ROLE_ARN` (repo) |
| `orderlab-cd-deploy-<env>-role` | staging, production | `<prefix>:environment:<env>` | pull from ECR, read that environment's secret | `AWS_DEPLOY_OIDC_ROLE_ARN` (environment) |
| `orderlab-runtime-<env>-role` | staging, production | none (ECS/EC2 service) | read that environment's secret | — |

`<prefix>` is `repo:sdpb@53051637/ai-platform-lab@1410420274`: this repo uses GitHub's immutable subject format (owner and repo IDs), so a renamed or re-created repo cannot inherit the trust. The build role cannot read secrets and only `main` can assume it. A deploy role can only be assumed by a job running in its GitHub Environment, which requires approval.

### 6. Terraform runs in CI after bootstrap

`.github/workflows/terraform.yml` runs on push to `main` (paths under `platform/terraform/`) and manually:

1. `checks`: `make tf-fmt` and `make tf-test` (no credentials).
2. `plan` (matrix shared, staging, production): plan goes to the job summary.
3. `apply` (one at a time, shared → staging → production): runs in the GitHub Environment of the same name, each with a required reviewer. It re-plans with `-out` and applies that exact plan. Plan files are never uploaded.

PRs never get cloud access (`pr.yml` runs fmt, `terraform test`, Checkov and Trivy only). Manual runs default to plan only. One concurrency group serializes runs and never cancels one mid-apply.

Plan and apply both use the single pre-existing role `sapb-training-deployer` (`vars.TF_DEPLOYER_ROLE_ARN`). It is managed outside this repo, like the bootstrap admin. Its trust allows exactly `<prefix>:ref:refs/heads/main` and `<prefix>:environment:{shared,staging,production}`.

---

## Consequences

- Bootstrap and the first apply need a local admin login; everything after goes through reviewed CI.
- One deployer role for plan and apply means plans are not least-privilege. Environment approval is the control.
- The deployer still has `AdministratorAccess`; its trust is limited to this repo's `main` and approval-gated environments. Splitting a read-only plan role from the apply role is the next hardening step.
- The sandbox account's GitHub OIDC provider was made by hand. `shared` adopts it with an import block, ignores all changes to it and refuses to destroy it; a fresh account drops `import.tf` and the lifecycle block and lets `shared` create it.
- Adding an environment means a new folder under `environments/` and a new GitHub Environment; modules do not change.

**Evidence to attach:** clean `terraform plan` after apply; IAM credential report with 0 access keys; `terraform state pull` showing no secret values; role trust policies.
