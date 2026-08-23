variable "region" {
  description = "AWS region for every resource in this module."
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

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread public/private subnets across. The ALB requires at least 2."
  type        = number
  default     = 2
}

variable "admission_api_container_port" {
  description = "Port the Admission API container listens on."
  type        = number
  default     = 80
}

variable "queue_controller_container_port" {
  description = "Port the Queue Controller container listens on (health check only, no real traffic)."
  type        = number
  default     = 80
}
