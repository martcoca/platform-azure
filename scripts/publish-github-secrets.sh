#!/usr/bin/env bash
# Transfer post-apply workflow values without placing them in shell variables or logs.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <owner/repository>\n' "$0" >&2
  exit 2
fi

repository=$1

command -v tofu >/dev/null 2>&1 || {
  printf 'publish-github-secrets requires OpenTofu.\n' >&2
  exit 2
}
command -v gh >/dev/null 2>&1 || {
  printf 'publish-github-secrets requires the GitHub CLI.\n' >&2
  exit 2
}

publish() {
  local output_name=$1
  local secret_name=$2

  tofu output -raw "$output_name" | gh secret set "$secret_name" --repo "$repository"
  printf 'Set %s\n' "$secret_name"
}

publish client_id AZURE_CLIENT_ID
publish tenant_id AZURE_TENANT_ID
publish subscription_id AZURE_SUBSCRIPTION_ID
publish resource_group_name AZURE_RESOURCE_GROUP
publish state_storage_account_name AZURE_STATE_STORAGE_ACCOUNT
publish state_container_name AZURE_STATE_CONTAINER
publish federated_subject AZURE_GITHUB_OIDC_SUBJECT
