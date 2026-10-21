provider "aws" {
  region = var.aws_region
}

module "secrets" {
  source = "../../modules/secrets"

  name                    = "orderlab-secrets"
  environment             = "production"
  recovery_window_in_days = 30
  tags                    = var.tags
}

module "iam" {
  source = "../../modules/iam"

  github_org                 = var.github_org
  github_repo                = var.github_repo
  environment                = "production"
  create_oidc_provider       = var.create_oidc_provider
  existing_oidc_provider_arn = var.existing_oidc_provider_arn

  create_build_role       = false
  create_deploy_role      = false
  create_app_runtime_role = true

  ecr_repository_arn = var.ecr_repository_arn
  secret_arns        = [module.secrets.secret_arn]
  tags               = var.tags
}

# Adopt pre-existing AWS Deployer Role (Seeded configuration drift exercise)
# import {
#   to = module.iam.aws_iam_role.cd_deploy[0]
#   id = "sapb-cd-deploy-production-role"
#}

