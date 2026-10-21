output "secret_arn" {
  description = "The ARN of the AWS Secrets Manager secret."
  value       = aws_secretsmanager_secret.this.arn
}

output "secret_id" {
  description = "The ID of the AWS Secrets Manager secret."
  value       = aws_secretsmanager_secret.this.id
}

output "secret_name" {
  description = "The friendly name of the secret."
  value       = aws_secretsmanager_secret.this.name
}

output "read_policy_arn" {
  description = "The ARN of the IAM policy granting read access to this secret."
  value       = aws_iam_policy.read_secret.arn
}

output "secret_keys" {
  description = "List of key names stored within the secret object (values masked for security)."
  value       = keys(local.combined_secrets)
  sensitive   = true
}
