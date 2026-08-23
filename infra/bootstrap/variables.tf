variable "region" {
  description = "AWS region for the Terraform state bucket. Must match every other module's region."
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Short project prefix used in resource names."
  type        = string
  default     = "waitly"
}

variable "owner" {
  description = "Value for the mandatory Owner tag."
  type        = string
  default     = "Ibrahim Babar"
}

variable "environment" {
  description = "Value for the mandatory Environment tag."
  type        = string
  default     = "sandbox"
}
