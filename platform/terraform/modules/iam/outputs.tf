output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = local.oidc_provider_arn
}

output "ci_build_role_arn" {
  description = "ARN of the CI build role for GitHub Actions."
  value       = length(aws_iam_role.ci_build) > 0 ? aws_iam_role.ci_build[0].arn : null
}

output "ci_build_role_name" {
  description = "Name of the CI build role for GitHub Actions."
  value       = length(aws_iam_role.ci_build) > 0 ? aws_iam_role.ci_build[0].name : null
}

output "cd_deploy_role_arn" {
  description = "ARN of the CD deployment role for GitHub Actions."
  value       = length(aws_iam_role.cd_deploy) > 0 ? aws_iam_role.cd_deploy[0].arn : null
}

output "cd_deploy_role_name" {
  description = "Name of the CD deployment role for GitHub Actions."
  value       = length(aws_iam_role.cd_deploy) > 0 ? aws_iam_role.cd_deploy[0].name : null
}

output "app_runtime_role_arn" {
  description = "ARN of the application runtime role."
  value       = length(aws_iam_role.app_runtime) > 0 ? aws_iam_role.app_runtime[0].arn : null
}

output "app_runtime_role_name" {
  description = "Name of the application runtime role."
  value       = length(aws_iam_role.app_runtime) > 0 ? aws_iam_role.app_runtime[0].name : null
}
