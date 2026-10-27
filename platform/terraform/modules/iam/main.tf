locals {
  oidc_provider_arn = var.create_oidc_provider ? (
    length(aws_iam_openid_connect_provider.github_actions) > 0 ? aws_iam_openid_connect_provider.github_actions[0].arn : ""
  ) : var.existing_oidc_provider_arn

  oidc_issuer = "token.actions.githubusercontent.com"
}

# GitHub Actions OIDC Provider
resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://${local.oidc_issuer}"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c587692c60e71e49751a350db0d44dfec73d2dc",
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# CI BUILD ROLE (Assumed by GitHub Actions on push to build/push to ECR)
# ---------------------------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "ci_build_assume_role" {
  count = var.create_build_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only main may push images; PRs and feature branches cannot assume this role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_build" {
  count = var.create_build_role ? 1 : 0

  name                 = "orderlab-ci-build-${var.environment}-role"
  assume_role_policy   = data.aws_iam_policy_document.ci_build_assume_role[0].json
  description          = "GitHub Actions CI role for building and pushing container images to ECR"
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "ci_build_policy" {
  count = var.create_build_role ? 1 : 0

  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "ci_build" {
  count = var.create_build_role ? 1 : 0

  name   = "orderlab-ci-build-policy"
  role   = aws_iam_role.ci_build[0].id
  policy = data.aws_iam_policy_document.ci_build_policy[0].json
}

# ---------------------------------------------------------------------------------------------------------------------
# CD DEPLOY ROLE (Assumed by GitHub Actions deployment jobs scoped to the environment)
# ---------------------------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "cd_deploy_assume_role" {
  count = var.create_deploy_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "cd_deploy" {
  count = var.create_deploy_role ? 1 : 0

  name                 = "orderlab-cd-deploy-${var.environment}-role"
  assume_role_policy   = data.aws_iam_policy_document.cd_deploy_assume_role[0].json
  description          = "GitHub Actions CD role scoped strictly to the ${var.environment} deployment environment"
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "cd_deploy_policy" {
  count = var.create_deploy_role ? 1 : 0

  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [var.ecr_repository_arn]
  }

  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []
    content {
      sid    = "SecretsAccess"
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      resources = var.secret_arns
    }
  }
}

resource "aws_iam_role_policy" "cd_deploy" {
  count = var.create_deploy_role ? 1 : 0

  name   = "orderlab-cd-deploy-${var.environment}-policy"
  role   = aws_iam_role.cd_deploy[0].id
  policy = data.aws_iam_policy_document.cd_deploy_policy[0].json
}

# ---------------------------------------------------------------------------------------------------------------------
# APP RUNTIME ROLE (Assumed by OrderLab container runtime to read secrets and config)
# ---------------------------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "app_runtime_assume_role" {
  count = var.create_app_runtime_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "ecs-tasks.amazonaws.com",
        "ec2.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "app_runtime" {
  count = var.create_app_runtime_role ? 1 : 0

  name               = "orderlab-runtime-${var.environment}-role"
  assume_role_policy = data.aws_iam_policy_document.app_runtime_assume_role[0].json
  description        = "Application execution role for OrderLab in ${var.environment}"

  tags = var.tags
}

data "aws_iam_policy_document" "app_runtime_policy" {
  count = var.create_app_runtime_role ? 1 : 0

  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []
    content {
      sid    = "ReadAppSecrets"
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      resources = var.secret_arns
    }
  }
}

resource "aws_iam_role_policy" "app_runtime" {
  count = var.create_app_runtime_role && length(var.secret_arns) > 0 ? 1 : 0

  name   = "orderlab-runtime-${var.environment}-policy"
  role   = aws_iam_role.app_runtime[0].id
  policy = data.aws_iam_policy_document.app_runtime_policy[0].json
}
