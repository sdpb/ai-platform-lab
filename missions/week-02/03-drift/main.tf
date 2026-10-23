terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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

# Resource managed by code; used for the "Restore" scenario
resource "aws_ssm_parameter" "managed" {
  name  = "/lab-w2/drift/managed"
  type  = "String"
  value = "intended-by-code"
}
