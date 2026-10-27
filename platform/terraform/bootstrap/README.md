# Terraform Remote State Bootstrap

This directory provisions the foundational AWS infrastructure required to host Terraform remote state securely and with locking:

- **S3 Bucket**: Encrypted, versioned, private S3 bucket storing state files. `force_destroy` is on so the lab can be torn down often.
- **KMS Key**: Customer Managed Key (CMK) with automated key rotation for server-side encryption of state files.
- **Public Access Block**: Enforces private access only, preventing any public leakage of state data.
- **DynamoDB Lock Table**: Distributed locking table with `LockID` primary key (used by Terraform S3 backend).
- **Native S3 Locking Support**: Fully compatible with Terraform 1.10+ native lockfiles (`use_lockfile = true`) as well as DynamoDB locking.

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

3. Note the output bucket name and DynamoDB table name. Supply them to the `backend.tf` files or `-backend-config` flags in the environment directories (`staging`, `production`, `shared`).
