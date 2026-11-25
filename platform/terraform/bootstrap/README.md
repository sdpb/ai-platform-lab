# Terraform Remote State Bootstrap

This directory provisions the foundational AWS infrastructure required to host Terraform remote state securely and with locking:

- **S3 Bucket**: Encrypted, versioned, private S3 bucket storing state files. `force_destroy` is on so the lab can be torn down often.
- **KMS Key**: Customer Managed Key (CMK) with automated key rotation for server-side encryption of state files.
- **Public Access Block**: Enforces private access only, preventing any public leakage of state data.
- **Locking**: native S3 lockfiles (`use_lockfile = true`, Terraform 1.10+); no DynamoDB table.

## Usage

1. Initialize Terraform locally:
   ```bash
   terraform init
   ```

2. Plan and apply:
   ```bash
   terraform plan -out=tfplan -var="state_bucket_name=my-company-orderlab-tfstate"
   terraform apply tfplan
   ```

3. Note the output bucket name. Supply it to the `backend.tf` files or `-backend-config` flags in the environment directories (`staging`, `production`, `shared`).
