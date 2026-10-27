# Terraform infrastructure

Base AWS infrastructure for OrderLab: remote state, ECR, GitHub OIDC roles, Secrets Manager, one state per environment. Design and trade-offs: [ADR-001](../../docs/adr/001-iac-and-environment-strategy.md).

```
platform/terraform/
├── bootstrap/          # State bucket (S3, KMS, versioning) + DynamoDB lock table. Local state.
├── modules/
│   ├── ecr/            # Immutable tags, scan on push, lifecycle rules
│   ├── iam/            # GitHub OIDC provider, CI build role, CD deploy role, runtime role
│   └── secrets/        # Secrets Manager; ephemeral + write-only values (nothing in state)
└── environments/
    ├── shared/         # ECR, OIDC provider, CI build role (main branch only)
    ├── staging/        # Secret, deploy role (GitHub Environment "staging"), runtime role
    └── production/     # Secret, deploy role (GitHub Environment "production"), runtime role
```

Everything is easy to destroy on purpose (`force_destroy`, no recovery window on secrets): this account is rebuilt often.

## Deploy from scratch

Needs Terraform ≥ 1.11 and an admin login (`asp sandbox login`, then `export AWS_PROFILE=sandbox`). Only bootstrap and the first apply run locally; later changes go through `.github/workflows/terraform.yml`.

The account can hold only one GitHub OIDC provider. In the sandbox account it already exists, so `environments/shared/import.tf` adopts it untouched (all changes ignored, destroy blocked). In a fresh account, delete `import.tf` and the `lifecycle` block on `aws_iam_openid_connect_provider` so `shared` creates it.

Role trust uses GitHub's immutable subject (`oidc_subject_prefix`). Check yours with `gh api repos/<org>/<repo>/actions/oidc/customization/sub`.

```bash
cd platform/terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=sdpb-orderlab-tfstate"

# Order matters: staging and production look up what shared creates.
for env in shared staging production; do
  cd ../environments/$env
  terraform init -backend-config="bucket=sdpb-orderlab-tfstate"
  terraform apply -var="github_org=sdpb"
done
```

Then point GitHub at the roles (the names are fixed, so the ARNs are known up front):

```bash
A=arn:aws:iam::986608278121:role
gh secret set AWS_BUILD_OIDC_ROLE_ARN --body "$A/orderlab-ci-build-shared-role"
gh secret set AWS_DEPLOY_OIDC_ROLE_ARN --env staging --body "$A/orderlab-cd-deploy-staging-role"
gh secret set AWS_DEPLOY_OIDC_ROLE_ARN --env production --body "$A/orderlab-cd-deploy-production-role"
```

Repository variables used by the workflows: `AWS_REGION`, `ECR_REPOSITORY`, `TF_STATE_BUCKET`, `TF_DEPLOYER_ROLE_ARN`. GitHub Environments `shared`, `staging` and `production` each need a required reviewer. Destroying `shared` fails on purpose while the provider is adopted; run `terraform state rm 'module.iam.aws_iam_openid_connect_provider.github_actions[0]'` first.

Rotate generated secrets: bump `secret_version` on the `secrets` module and apply.

## Checks

```bash
make tf-fmt tf-validate tf-test
```

`tf-test` runs plan-only `terraform test` with mocked providers; no credentials needed. The same checks run on every PR.
