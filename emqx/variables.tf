variable "github_app" {
  description = "GitHub for API usages."
  sensitive = true

  type = object({
    id         = string
    key_base64 = string
  })
  default = null
}

variable "environment" {
  type    = string
  default = null
}
