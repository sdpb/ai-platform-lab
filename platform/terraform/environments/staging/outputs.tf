output "cd_deploy_role_arn" {
  description = "Role ARN to set for AWS_DEPLOY_OIDC_ROLE_ARN in GitHub Environment 'staging' secrets."
  value       = module.iam.cd_deploy_role_arn
}

output "app_runtime_role_arn" {
  description = "Execution role ARN for the OrderLab container runtime in staging."
  value       = module.iam.app_runtime_role_arn
}

output "secrets_manager_secret_arn" {
  description = "ARN of the staging application secret in AWS Secrets Manager."
  value       = module.secrets.secret_arn
}

output "secrets_manager_secret_name" {
  description = "Name of the staging secret in AWS Secrets Manager."
  value       = module.secrets.secret_name
}

output "secret_keys" {
  description = "List of key names stored within the secret object (values masked for security)."
  value       = module.secrets.secret_keys
}
