output "state_bucket_name" {
  description = "The name of the S3 bucket created for Terraform state storage."
  value       = aws_s3_bucket.state_bucket.id
}

output "state_bucket_arn" {
  description = "The ARN of the S3 bucket created for Terraform state storage."
  value       = aws_s3_bucket.state_bucket.arn
}

output "kms_key_arn" {
  description = "The ARN of the KMS key used for encrypting the remote state."
  value       = aws_kms_key.state_key.arn
}

output "dynamodb_table_name" {
  description = "The name of the DynamoDB table configured for state locking."
  value       = aws_dynamodb_table.state_lock.id
}

output "dynamodb_table_arn" {
  description = "The ARN of the DynamoDB table configured for state locking."
  value       = aws_dynamodb_table.state_lock.arn
}
