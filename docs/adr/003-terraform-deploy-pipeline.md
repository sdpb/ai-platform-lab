# ADR-003: Terraform deploy pipeline

## Status

Accepted

## Context

Terraform was applied from laptops. We want reviewed, repeatable applies without long-lived keys, consistent with ADR-001 (PRs have no cloud access) and ADR-002 (one state per environment). Simplicity wins for this lab.

## Decision

`.github/workflows/terraform.yml` runs on push to `main` (paths under `platform/terraform/`) and manually:

1. `checks`: `make tf-fmt` and `make tf-test` (no credentials).
2. `plan` (matrix shared/staging/production): assumes the single pre-existing IAM role `sapb-training-deployer` through OIDC. Output goes to the job summary.
3. `apply` (matrix, `max-parallel: 1`, order shared -> staging -> production): same role, gated by the GitHub Environments `tf-shared|tf-staging|tf-production` (required reviewers). It re-plans with `-out` and applies that exact plan; plan files are never uploaded (they contain generated secrets).

- A global concurrency group serializes runs; runs are never cancelled mid-apply.
- Manual runs default to plan-only.

The role ARN lives in the repository variable `TF_DEPLOYER_ROLE_ARN`. The role is managed outside this repo, so no Terraform here creates CI roles.

## Consequences

- One role for plan and apply means plans are not least-privilege. Environment approval and branch protection on `main` are the controls.
- The role's trust policy must allow the OIDC subjects `repo:<org>/<repo>:ref:refs/heads/main` (plan) and `repo:<org>/<repo>:environment:tf-<env>` (apply), audience `sts.amazonaws.com`.
- The role needs access to the state bucket, its KMS key, and the resources the stacks manage.

## One-time setup

Variables: `AWS_REGION`, `TF_STATE_BUCKET`, `ECR_REPOSITORY_ARN`, `OIDC_PROVIDER_ARN`, `TF_DEPLOYER_ROLE_ARN`. Environments `tf-shared`, `tf-staging`, `tf-production` with required reviewers. Branch protection on `main`.
