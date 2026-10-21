output "ecr_repository_url" {
  description = "The URL of the ECR repository (configure as ECR_REPOSITORY in GitHub vars/secrets)."
  value       = module.ecr.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository."
  value       = module.ecr.repository_arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = module.iam.oidc_provider_arn
}

output "ci_build_role_arn" {
  description = "Role ARN to set for AWS_BUILD_OIDC_ROLE_ARN in GitHub Secrets."
  value       = module.iam.ci_build_role_arn
}
