# Ephemeral: generated in memory during plan/apply, never written to state or plan files.
ephemeral "random_password" "db_password" {
  count = var.generate_random_passwords ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

ephemeral "random_password" "admin_token" {
  count = var.generate_random_passwords ? 1 : 0

  length  = 32
  special = false
}

ephemeral "random_password" "grafana_password" {
  count = var.generate_random_passwords ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

locals {
  generated_keys = var.generate_random_passwords ? ["POSTGRES_PASSWORD", "LAB_ADMIN_TOKEN", "GRAFANA_PASSWORD"] : []
}

resource "aws_secretsmanager_secret" "this" {
  name                    = "${var.environment}/${var.name}"
  description             = var.description
  kms_key_id              = var.kms_key_id
  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}

# Write-only: sent to AWS, never stored in state. Terraform cannot diff a value it does not
# store, so new passwords are only written when secret_version changes.
resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id
  secret_string_wo = jsonencode(merge(
    var.generate_random_passwords ? {
      POSTGRES_PASSWORD = ephemeral.random_password.db_password[0].result
      LAB_ADMIN_TOKEN   = ephemeral.random_password.admin_token[0].result
      GRAFANA_PASSWORD  = ephemeral.random_password.grafana_password[0].result
    } : {},
    var.custom_secrets,
  ))
  secret_string_wo_version = var.secret_version
}

data "aws_iam_policy_document" "read_secret" {
  statement {
    sid    = "AllowReadSecretValue"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_secretsmanager_secret.this.arn,
    ]
  }

  dynamic "statement" {
    for_each = var.kms_key_id != null ? [1] : []
    content {
      sid    = "AllowDecryptKmsKey"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = [
        var.kms_key_id,
      ]
    }
  }
}

resource "aws_iam_policy" "read_secret" {
  name        = "${var.environment}-${var.name}-read-policy"
  description = "Allows reading the application secret from AWS Secrets Manager for ${var.environment}"
  policy      = data.aws_iam_policy_document.read_secret.json

  tags = var.tags
}
