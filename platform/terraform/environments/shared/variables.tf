variable "aws_region" {
  description = "AWS region for shared infrastructure."
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

variable "repository_name" {
  description = "Name of the ECR repository for application container images."
  type        = string
  default     = "sapb-orderlab"
}

variable "create_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC provider (one per AWS account). Set false if the account already has one."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags for shared infrastructure."
  type        = map(string)
  default = {
    project     = "sapb-training"
    Environment = "shared"
    ManagedBy   = "terraform"
  }
}
