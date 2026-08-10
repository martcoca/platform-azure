output "client_id" {
  description = "Application (client) ID for the GitHub Actions login."
  value       = azuread_application.ci.client_id
  sensitive   = true
}

output "tenant_id" {
  description = "Tenant ID for the GitHub Actions login."
  value       = var.azure_tenant_id
  sensitive   = true
}

output "subscription_id" {
  description = "Subscription ID for the GitHub Actions login."
  value       = var.azure_subscription_id
  sensitive   = true
}

output "service_principal_object_id" {
  description = "Object ID of the federated service principal."
  value       = azuread_service_principal.ci.object_id
  sensitive   = true
}

output "resource_group_name" {
  description = "Bootstrap resource group used by the landing zone."
  value       = var.resource_group_name
  sensitive   = true
}

output "state_storage_account_name" {
  description = "Storage account that holds OpenTofu state."
  value       = var.state_storage_account_name
  sensitive   = true
}

output "state_container_name" {
  description = "Container backing OpenTofu state."
  value       = azurerm_storage_container.state.name
  sensitive   = true
}

output "federated_subject" {
  description = "The only OIDC subject that can assume the CI identity."
  value       = azuread_application_federated_identity_credential.github.subject
  sensitive   = true
}
