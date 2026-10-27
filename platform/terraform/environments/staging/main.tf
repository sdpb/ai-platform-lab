provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project = "sapb-training"
    }
  }
}

module "secrets" {
  source = "../../modules/secrets"

  name                    = "orderlab-secrets"
  environment             = "staging"
  recovery_window_in_days = 0
  tags                    = var.tags
}

# Created by the shared stack; looked up by name so no ARNs are passed between stacks.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_ecr_repository" "app" {
  name = var.repository_name
}

module "iam" {
  source = "../../modules/iam"

  github_org                 = var.github_org
  github_repo                = var.github_repo
  environment                = "staging"
  create_oidc_provider       = false
  existing_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  create_build_role       = false
  create_deploy_role      = true
  create_app_runtime_role = true

  ecr_repository_arn = data.aws_ecr_repository.app.arn
  secret_arns        = [module.secrets.secret_arn]
  tags               = var.tags
}
