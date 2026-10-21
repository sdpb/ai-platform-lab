variable "github_org" {
  description = "The GitHub organization or username owning the repository."
  type        = string
}

variable "github_repo" {
  description = "The repository name in GitHub (without org)."
  type        = string
}

variable "environment" {
  description = "Deployment environment name (e.g., staging, production, shared)."
  type        = string
  default     = "shared"
}

variable "create_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC provider in this AWS account. Set to false if it already exists."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider if create_oidc_provider is false."
  type        = string
  default     = ""
}

variable "create_build_role" {
  description = "Whether to create the CI Build role for GitHub Actions."
  type        = bool
  default     = false
}

variable "create_deploy_role" {
  description = "Whether to create the CD Deploy role for GitHub Actions."
  type        = bool
  default     = false
}

variable "create_app_runtime_role" {
  description = "Whether to create the runtime execution role for OrderLab."
  type        = bool
  default     = false
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository to scope push/pull permissions."
  type        = string
  default     = "*"
}

variable "secret_arns" {
  description = "List of Secrets Manager secret ARNs that the deploy and runtime roles may access."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "A map of tags to assign to the IAM resources."
  type        = map(string)
  default     = {}
}
