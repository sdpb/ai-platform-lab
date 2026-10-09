# Remote state backend configuration for shared/foundation infrastructure
# Supply the bucket name either directly here or via:
#   terraform init -backend-config="bucket=<STATE_BUCKET_NAME>"

terraform {
  backend "s3" {
    key          = "shared/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # Native S3 locking (Terraform 1.10+)
    # dynamodb_table = "orderlab-terraform-state-lock" # Fallback for pre-1.10 or defense-in-depth
  }
}
