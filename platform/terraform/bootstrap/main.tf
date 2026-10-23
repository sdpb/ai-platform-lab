provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project = "sapb-training"
    }
  }
}

# KMS Key for state encryption
resource "aws_kms_key" "state_key" {
  description             = "KMS Customer Managed Key for encrypting Terraform remote state"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(
    var.tags,
    {
      Name = "${var.state_bucket_name}-kms-key"
    }
  )
}

resource "aws_kms_alias" "state_key" {
  name          = "alias/${var.state_bucket_name}-key"
  target_key_id = aws_kms_key.state_key.key_id
}

# S3 Bucket for Terraform Remote State
resource "aws_s3_bucket" "state_bucket" {
  bucket        = var.state_bucket_name
  force_destroy = true

  tags = merge(
    var.tags,
    {
      Name = var.state_bucket_name
    }
  )

  lifecycle {
    prevent_destroy = false
  }
}

# Enable Object Versioning to prevent accidental state loss and enable rollbacks
resource "aws_s3_bucket_versioning" "state_bucket" {
  bucket = aws_s3_bucket.state_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enforce KMS Server-Side Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "state_bucket" {
  bucket = aws_s3_bucket.state_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.state_key.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "state_bucket" {
  bucket = aws_s3_bucket.state_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB Table for distributed locking (works alongside or alternative to S3 native lockfiles)
resource "aws_dynamodb_table" "state_lock" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = merge(
    var.tags,
    {
      Name = var.dynamodb_table_name
    }
  )

  lifecycle {
    prevent_destroy = false
  }
}
