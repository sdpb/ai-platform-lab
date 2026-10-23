# INTENTIONALLY INSECURE - throwaway lab, never apply this pattern for real.
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
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

# LEAK 1: generated value is persisted in state as plaintext
resource "random_password" "db" {
  length  = 24
  special = false
}

# LEAK 2: hardcoded credential committed to the repo
locals {
  legacy_api_key = "AKIAIOSFODNN7EXAMPLE"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "lab-w2/leak/db-password"
  recovery_window_in_days = 0
}

# secret_string is a normal attribute, so it is stored in terraform.tfstate
resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}

# LEAK 3: plain String SSM parameter holding a credential
resource "aws_ssm_parameter" "api_key" {
  name  = "/lab-w2/leak/api-key"
  type  = "String"
  value = local.legacy_api_key
}
