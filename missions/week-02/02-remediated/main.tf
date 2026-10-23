terraform {
  required_version = ">= 1.11.0" # write-only attributes
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7" # ephemeral random_password
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      project = "sapb-training"
    }
  }
}

# Ephemeral: exists only in memory during plan/apply, never written to state or plan
ephemeral "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "lab-w2/fixed/db-password"
  recovery_window_in_days = 0
}

# Write-only attribute: sent to AWS, never stored in state.
# Bump secret_string_wo_version to rotate (Terraform cannot diff a value it never stores).
resource "aws_secretsmanager_secret_version" "db" {
  secret_id                = aws_secretsmanager_secret.db.id
  secret_string_wo         = ephemeral.random_password.db.result
  secret_string_wo_version = 1
}

# Credential supplied at runtime (TF_VAR_api_key); ephemeral variables never reach state or plan
variable "api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

resource "aws_ssm_parameter" "api_key" {
  name             = "/lab-w2/fixed/api-key"
  type             = "SecureString"
  value_wo         = var.api_key
  value_wo_version = 1
}
