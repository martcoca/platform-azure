# The resource group and state storage account are bootstrap resources: they must exist
# before this root can keep its own state, so they are created by hand once and read here.
# Everything else in the landing zone is managed.
data "azurerm_resource_group" "platform" {
  name = var.resource_group_name
}

data "azurerm_storage_account" "state" {
  name                = var.state_storage_account_name
  resource_group_name = data.azurerm_resource_group.platform.name
}

resource "azurerm_storage_container" "state" {
  name                  = var.state_container_name
  storage_account_id    = data.azurerm_storage_account.state.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Keyless GitHub Actions identity
#
# No client secret resource exists anywhere in this root. The application is reachable
# only through a federated credential bound to one repository and one ref, so a token
# minted by any other workflow — including one in another repository in this
# organization — fails to match and is refused.
# ---------------------------------------------------------------------------

resource "azuread_application" "ci" {
  display_name     = "github-actions-platform-azure"
  sign_in_audience = "AzureADMyOrg"

  description = "Keyless CI identity. No secret; federated only."
}

resource "azuread_service_principal" "ci" {
  client_id = azuread_application.ci.client_id
}

resource "azuread_application_federated_identity_credential" "github" {
  application_id = azuread_application.ci.id
  display_name   = "github-main"
  description    = "GitHub Actions on the authorized main branch."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = var.github_oidc_subject
}

# ---------------------------------------------------------------------------
# Least privilege
#
# Contributor is scoped to the one resource group, never the subscription, so CI cannot
# touch the Policy assignment or the budget that constrain it. Blob Data Contributor is
# scoped to the state account alone and is required because shared-key access is off.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "ci_resource_group" {
  scope                = data.azurerm_resource_group.platform.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.ci.object_id
}

resource "azurerm_role_assignment" "ci_state" {
  scope                = data.azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.ci.object_id
}
