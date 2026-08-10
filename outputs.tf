output "client_id" {
  description = "Application (client) ID for the GitHub Actions login."
  value       = azuread_application.ci.client_id
}

output "tenant_id" {
  description = "Tenant ID for the GitHub Actions login."
  value       = var.azure_tenant_id
}

output "state_container" {
  description = "Container backing OpenTofu state."
  value       = azurerm_storage_container.state.name
}

output "federated_subject" {
  description = "The only OIDC subject that can assume the CI identity."
  value       = azuread_application_federated_identity_credential.github.subject
}
