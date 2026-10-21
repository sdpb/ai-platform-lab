# Terraform Base Infrastructure

This directory contains the production-grade Terraform infrastructure for OrderLab, following modern IaC patterns (Terraform >= 1.10) with strict security isolation, supply chain controls, and least-privilege IAM policies.

## Architecture & State Isolation

```
terraform/
├── bootstrap/               # One-time bootstrap: S3 remote state bucket, KMS encryption, DynamoDB lock table
├── modules/                 # Single-responsibility resource modules
│   ├── ecr/                 # ECR repository: AES-256 encryption, image immutability, vulnerability scan on push, lifecycle rules
│   ├── iam/                 # OIDC provider + CI Build role + CD Deploy role + App Runtime role
│   └── secrets/             # AWS Secrets Manager: KMS encryption, auto-generated secure credentials, reader IAM policy
└── environments/            # Separate remote state per environment (reduced blast radius)
    ├── shared/              # Shared CI/CD stack: ECR repository & CI Build role
    ├── staging/             # Staging stack: Staging secrets & CD Deploy role (scoped to env:staging)
    └── production/          # Production stack: Production secrets & CD Deploy role (scoped to env:production)
```

### Key Pillars

1. **S3 Remote State with Distributed Locking**
   - **Terraform 1.10+ Native Locking**: State backends use `use_lockfile = true`, storing mutex locks natively in S3 without mandatory external table requirements.
   - **Dual-Mode Compatibility**: A DynamoDB state lock table is also provisioned during bootstrap for teams requiring backwards compatibility or defense-in-depth locking.
   - **Data Protection**: Object versioning is enabled on the state bucket to protect against accidental state corruption or deletion, combined with KMS Customer Managed Key encryption and strict `block_public_access`.

2. **Separate State per Environment (Blast Radius Minimization)**
   - Staging (`staging/terraform.tfstate`), Production (`production/terraform.tfstate`), and Shared (`shared/terraform.tfstate`) maintain completely isolated state files and lifecycles.
   - Changes or state lock acquisitions in `staging` cannot impact or corrupt `production`.

3. **Amazon ECR with Supply Chain Hardening**
   - **Tag Immutability (`IMMUTABLE`)**: Tags cannot be overwritten once pushed, guaranteeing digest stability and provenance authenticity.
   - **Vulnerability Scanning**: Automated scanning on push (`scan_on_push = true`) evaluates images for CVEs immediately.
   - **Lifecycle Management**: Cleans untagged intermediate layers after 14 days and retains the last 30 releases to control storage costs.

4. **GitHub Actions IAM Roles via OIDC Federation**
   - **No Long-Lived Static Keys**: Uses AWS IAM OpenID Connect (OIDC) federation with GitHub Actions (`token.actions.githubusercontent.com`).
   - **Role Separation**:
     - `ci_build_role`: Scoped to push images to ECR. (Supplied to GitHub Secret `AWS_BUILD_OIDC_ROLE_ARN`).
     - `cd_deploy_role`: Scoped strictly by GitHub Environment (`repo:<org>/<repo>:environment:staging` or `production`), only permitting image pulls and retrieval of that environment's Secrets Manager secret. (Supplied to GitHub Environment Secret `AWS_DEPLOY_OIDC_ROLE_ARN`).

5. **AWS Secrets Manager**
   - Stores application secrets (`POSTGRES_PASSWORD`, `LAB_ADMIN_TOKEN`, `GRAFANA_PASSWORD`) securely in AWS Secrets Manager.
   - Sensitive material is never committed to Git or stored in plaintext `.env` files.
   - Least-privilege IAM reader policies are generated per secret and attached to deploy and runtime roles.

---

## Deployment & Setup Guide

### 1. Bootstrap State Backend (Run Once)

```bash
cd terraform/bootstrap
terraform init
terraform plan -var="state_bucket_name=sdpb-orderlab-tfstate" -out=tfplan
terraform apply tfplan
```

Note the output `state_bucket_name`.

### 2. Deploy Shared CI/CD Infrastructure (ECR & Build Role)

```bash
cd ../environments/shared
terraform init -backend-config="bucket=sdpb-orderlab-tfstate"
terraform plan -var="github_org=sdpb" -var="github_repo=ai-platform-lab" -out=tfplan
terraform apply tfplan
```

Outputs will provide:

- `ecr_repository_url` (add as GitHub repository variable `ECR_REPOSITORY`)
- `ci_build_role_arn` (add as GitHub repository secret `AWS_BUILD_OIDC_ROLE_ARN`)

### 3. Deploy Staging Environment

```bash
cd ../environments/staging
terraform init -backend-config="bucket=sdpb-orderlab-tfstate"
terraform plan -var="github_org=sdpb" -var="github_repo=ai-platform-lab" -var="ecr_repository_arn=arn:aws:ecr:us-east-1:986608278121:repository/sapb-orderlab" -out=tfplan
terraform apply tfplan
```

Set the output `cd_deploy_role_arn` as secret `AWS_DEPLOY_OIDC_ROLE_ARN` inside the GitHub `staging` Environment.

### 4. Deploy Production Environment

```bash
cd ../environments/production
terraform init -backend-config="bucket=sdpb-orderlab-tfstate"
terraform plan -var="github_org=sdpb" -var="github_repo=ai-platform-lab" -var="ecr_repository_arn=arn:aws:ecr:us-east-1:986608278121:repository/sapb-orderlab" -out=tfplan
terraform apply tfplan
```

Set the output `cd_deploy_role_arn` as secret `AWS_DEPLOY_OIDC_ROLE_ARN` inside the GitHub `production` Environment.

---

## Validation & Formatting

Run format checks and validation locally:

```bash
make tf-fmt
make tf-validate
```
