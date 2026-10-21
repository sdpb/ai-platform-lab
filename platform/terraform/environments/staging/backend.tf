# Remote state backend configuration for staging environment
# Supply the bucket name either directly here or via:
#   terraform init -backend-config="bucket=<STATE_BUCKET_NAME>"

terraform {
  backend "s3" {
    key          = "staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # Native S3 locking (Terraform 1.10+)
    # dynamodb_table = "orderlab-terraform-state-lock" # Fallback for pre-1.10 or defense-in-depth
  }
}
