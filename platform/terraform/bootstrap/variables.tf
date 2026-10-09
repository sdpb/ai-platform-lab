variable "aws_region" {
  description = "The AWS region where remote state resources are provisioned."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the S3 bucket storing Terraform remote state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "The state_bucket_name must be between 3 and 63 characters, lower-case alphanumeric, dots, or hyphens."
  }
}

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking (optional on TF 1.10+ with native S3 locking, but provided for dual-compatibility)."
  type        = string
  default     = "orderlab-terraform-state-lock"
}

variable "tags" {
  description = "Common tags applied to all bootstrap resources."
  type        = map(string)
  default = {
    Project   = "orderlab"
    ManagedBy = "terraform"
    Role      = "state-bootstrap"
  }
}
