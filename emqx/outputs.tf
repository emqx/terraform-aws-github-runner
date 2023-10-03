output "webhook_endpoint" {
  value = module.runners.webhook.endpoint
}

output "webhook_secret" {
  value     = local.webhook_secret
  sensitive = true
}

