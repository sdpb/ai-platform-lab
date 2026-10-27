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

variable "repository_name" {
  description = "Name of the ECR repository created by the shared stack."
  type        = string
  default     = "sapb-orderlab"
}

variable "oidc_subject_prefix" {
  description = "GitHub OIDC sub prefix. This repo uses immutable subjects (gh api repos/<org>/<repo>/actions/oidc/customization/sub)."
  type        = string
  default     = "repo:sdpb@53051637/ai-platform-lab@1410420274"
}

variable "tags" {
  description = "Common tags for production infrastructure."
  type        = map(string)
  default = {
    project     = "sapb-training"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
