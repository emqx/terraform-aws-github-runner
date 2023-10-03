variable "prefix" {
  type = string
}

variable "vpc_id" {
  type  = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "logging_retention_in_days" {
  type    = number
  default = 7
}

variable "enable_cloudwatch_agent" {
  type    = bool
  default = true
}

variable "route53_zone_name" {
  type = string
}

variable "route53_zone_id" {
  type = string
}
