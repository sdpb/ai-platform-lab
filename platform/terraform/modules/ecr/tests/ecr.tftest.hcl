# Plan-only tests: no AWS credentials or real resources needed.
mock_provider "aws" {}

variables {
  repository_name = "orderlab-test"
  tags            = { project = "sapb-training" }
}

run "secure_defaults" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "Tags must be IMMUTABLE by default so a pushed digest cannot be replaced."
  }

  assert {
    condition     = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push == true
    error_message = "scan_on_push must be enabled by default."
  }

  assert {
    condition     = aws_ecr_repository.this.encryption_configuration[0].encryption_type == "AES256"
    error_message = "Repository must be encrypted at rest."
  }

  assert {
    condition     = aws_ecr_repository.this.tags["project"] == "sapb-training"
    error_message = "Project tag must be propagated to the repository."
  }
}

run "lifecycle_policy_reflects_retention_inputs" {
  command = plan

  variables {
    untagged_retention_days = 7
    max_image_count         = 10
  }

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.this.policy).rules) == 2
    error_message = "Expected an untagged-expiry rule and a keep-last-N rule."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.countNumber == 7
    error_message = "Untagged retention must follow untagged_retention_days."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.countNumber == 10
    error_message = "Tagged image cap must follow max_image_count."
  }
}

run "rejects_invalid_repository_name" {
  command = plan

  variables {
    repository_name = "Invalid_Name!"
  }

  expect_failures = [var.repository_name]
}

run "rejects_invalid_mutability" {
  command = plan

  variables {
    image_tag_mutability = "SOMETIMES"
  }

  expect_failures = [var.image_tag_mutability]
}
