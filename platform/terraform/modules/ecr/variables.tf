variable "repository_name" {
  description = "The name of the ECR repository."
  type        = string
  default     = "orderlab"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,255}$", var.repository_name))
    error_message = "Repository name must be valid AWS ECR name format (lowercase alphanumeric, dots, underscores, dashes)."
  }
}

variable "image_tag_mutability" {
  description = "The tag mutability setting for the repository (IMMUTABLE or MUTABLE). Default is IMMUTABLE for tamper prevention."
  type        = string
  default     = "IMMUTABLE"
  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be either 'MUTABLE' or 'IMMUTABLE'."
  }
}

variable "scan_on_push" {
  description = "Indicates whether images are scanned after being pushed to the repository."
  type        = bool
  default     = true
}

variable "untagged_retention_days" {
  description = "Number of days to keep untagged container images before expiration."
  type        = number
  default     = 14
}

variable "max_image_count" {
  description = "Maximum number of tagged images to retain before older ones are expired."
  type        = number
  default     = 30
}

variable "tags" {
  description = "A map of tags to assign to the repository."
  type        = map(string)
  default     = {}
}
