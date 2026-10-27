variable "name" {
  description = "Base name for the AWS Secrets Manager secret."
  type        = string
  default     = "orderlab-app-secrets"
}

variable "environment" {
  description = "Deployment environment name (e.g. staging, production)."
  type        = string
}

variable "description" {
  description = "Description of the secret and its contents."
  type        = string
  default     = "Application credentials and configuration tokens managed by Terraform"
}

variable "kms_key_id" {
  description = "ARN or ID of the AWS KMS key used to encrypt the secret value. Set null to use the default AWS Secrets Manager key."
  type        = string
  default     = null
}

variable "recovery_window_in_days" {
  description = "Number of days that AWS Secrets Manager waits before deleting the secret. Can be 0 to force deletion without recovery."
  type        = number
  default     = 30
}

variable "generate_random_passwords" {
  description = "Whether to generate random passwords for the application credentials if not explicitly provided."
  type        = bool
  default     = true
}

variable "custom_secrets" {
  description = "Custom map of secrets to store in the secret version alongside or instead of generated passwords."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "tags" {
  description = "Tags to attach to the Secrets Manager secret."
  type        = map(string)
  default     = {}
}

variable "secret_version" {
  description = "Bump to generate and write new credentials (write-only values cannot be diffed)."
  type        = number
  default     = 1
}
