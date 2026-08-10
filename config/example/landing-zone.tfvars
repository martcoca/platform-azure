# Copy to config/local/landing-zone.tfvars and replace every REDACTED marker.
# config/local is ignored and must never be committed.

azure_subscription_id      = "REDACTED-SUBSCRIPTION-ID"
azure_tenant_id            = "REDACTED-TENANT-ID"
state_storage_account_name = "REDACTED-STORAGE-ACCOUNT"

resource_group_name  = "REDACTED-RESOURCE-GROUP"
location             = "eastus"
state_container_name = "tfstate"

# Immutable subject claim. Both numeric IDs are required; the name-based form
# will not match. Read it from a real token rather than composing it.
github_oidc_subject = "repo:REDACTED-OWNER@REDACTED-ORG-ID/REDACTED-REPOSITORY@REDACTED-REPO-ID:ref:refs/heads/main"
