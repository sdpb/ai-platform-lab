variable "aws_region" {
  description = "AWS region for production infrastructure."
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub organization or username owning the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
  default     = "ai-platform-lab"
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository to grant production deployment pull permissions."
  type        = string
  default     = "*"
}

variable "create_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC provider (false if created in shared stack or pre-existing)."
  type        = bool
  default     = false
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider if create_oidc_provider is false."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags for production infrastructure."
  type        = map(string)
  default = {
    Project     = "orderlab"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
