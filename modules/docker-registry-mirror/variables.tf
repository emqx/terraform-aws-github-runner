variable "vpc_id" {
  type  = string
}

variable "subnet_id" {
  type = string
}

variable "ingress_security_group_ids" {
  type = list(string)
}

variable "route53_zone_name" {
  type = string
}

variable "route53_zone_id" {
  type = string
}

variable "instance_arch" {
  type    = string
  default = "amd64"
  validation {
    condition     = can(regex("^(amd64|arm64)$", var.instance_arch))
    error_message = "instance_architecture must be either amd64 or arm64"
  }
}

variable "logging_retention_in_days" {
  type    = number
  default = 7
}

variable "prefix" {
  type = string
}
