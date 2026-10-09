resource "random_password" "db_password" {
  count = var.generate_random_passwords ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "admin_token" {
  count = var.generate_random_passwords ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "grafana_password" {
  count = var.generate_random_passwords ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

locals {
  generated_secrets = var.generate_random_passwords ? {
    POSTGRES_PASSWORD = random_password.db_password[0].result
    LAB_ADMIN_TOKEN   = random_password.admin_token[0].result
    GRAFANA_PASSWORD  = random_password.grafana_password[0].result
  } : {}

  combined_secrets = merge(local.generated_secrets, var.custom_secrets)
}

resource "aws_secretsmanager_secret" "this" {
  name                    = "${var.environment}/${var.name}"
  description             = var.description
  kms_key_id              = var.kms_key_id
  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = jsonencode(local.combined_secrets)
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
