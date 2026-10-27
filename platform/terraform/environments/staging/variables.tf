variable "aws_region" {
  description = "AWS region for staging infrastructure."
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

variable "tags" {
  description = "Common tags for staging infrastructure."
  type        = map(string)
  default = {
    project     = "sapb-training"
    Environment = "staging"
    ManagedBy   = "terraform"
  }
}
