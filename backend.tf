# Partial configuration. The state container is created by this root, so the first apply
# runs against local state and is then migrated:
#
#   tofu init \
#     -backend-config="resource_group_name=<resource group>" \
#     -backend-config="storage_account_name=<state storage account>" \
#     -backend-config="container_name=tfstate" \
#     -migrate-state
#
# use_azuread_auth is not optional here: the storage account has shared-key access
# disabled, so there is no account key for the backend to fall back to.
terraform {
  backend "azurerm" {
    key              = "landing-zone.tfstate"
    use_azuread_auth = true
  }
}
