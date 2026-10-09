provider "aws" {
  region = var.aws_region
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name      = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true

  tags = var.tags
}

module "iam" {
  source = "../../modules/iam"

  github_org           = var.github_org
  github_repo          = var.github_repo
  environment          = "shared"
  create_oidc_provider = var.create_oidc_provider

  create_build_role       = true
  create_deploy_role      = false
  create_app_runtime_role = false

  ecr_repository_arn = module.ecr.repository_arn
  tags               = var.tags
}
