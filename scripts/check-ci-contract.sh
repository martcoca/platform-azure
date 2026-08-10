#!/usr/bin/env bash
# Mechanically keep the public inputs, secret handoff, and CI safety contract aligned.

set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

require() {
  local needle=$1
  local file=$2
  if ! grep -Fq -- "$needle" "$file"; then
    printf 'Missing required contract text in %s: %s\n' "$file" "$needle" >&2
    exit 1
  fi
}

for output in client_id tenant_id subscription_id service_principal_object_id resource_group_name state_storage_account_name state_container_name federated_subject; do
  require "output \"${output}\"" outputs.tf
done

if [[ $(grep -c 'sensitive   = true' outputs.tf) -ne 8 ]]; then
  printf 'Every public post-apply identifier must be a sensitive output.\n' >&2
  exit 1
fi

if grep -Fq 'github_repository' variables.tf main.tf config/example/landing-zone.tfvars; then
  printf 'github_repository must not duplicate the authoritative OIDC subject.\n' >&2
  exit 1
fi
if awk '/variable "resource_group_name"/,/^}/' variables.tf | grep -Fq 'default'; then
  printf 'resource_group_name must be required.\n' >&2
  exit 1
fi

helper=scripts/publish-github-secrets.sh
for mapping in \
  'client_id AZURE_CLIENT_ID' \
  'tenant_id AZURE_TENANT_ID' \
  'subscription_id AZURE_SUBSCRIPTION_ID' \
  'resource_group_name AZURE_RESOURCE_GROUP' \
  'state_storage_account_name AZURE_STATE_STORAGE_ACCOUNT' \
  'state_container_name AZURE_STATE_CONTAINER' \
  'federated_subject AZURE_GITHUB_OIDC_SUBJECT'; do
  require "publish ${mapping}" "$helper"
done
require 'tofu output -raw "$output_name" | gh secret set "$secret_name" --repo "$repository"' "$helper"
if grep -Eq -- '--body|\$\(tofu output|tofu output.*>' "$helper"; then
  printf 'Secret values must travel directly over standard input.\n' >&2
  exit 1
fi

identity=.github/workflows/azure-identity.yml
if grep -Eq 'credential list|\|\|[[:space:]]*echo[[:space:]]+0' "$identity"; then
  printf 'The identity workflow must not fail open on credential inventory.\n' >&2
  exit 1
fi
require 'uses: azure/login@v2' "$identity"
require 'Assert the signed-in principal is the federated application' "$identity"

workflow=.github/workflows/guarded-plan.yml
require 'push:' "$workflow"
require 'main' "$workflow"
require 'workflow_dispatch:' "$workflow"
if grep -Fq 'pull_request' "$workflow"; then
  printf 'The guarded plan must not run for pull requests.\n' >&2
  exit 1
fi
require 'contents: read' "$workflow"
require 'id-token: write' "$workflow"
require 'uses: azure/login@v2' "$workflow"
require 'tofu_version: 1.12.5' "$workflow"
require 'tofu_wrapper: false' "$workflow"
require 'ARM_USE_OIDC: true' "$workflow"
require 'TF_VAR_azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}' "$workflow"
require 'TF_VAR_azure_tenant_id: ${{ secrets.AZURE_TENANT_ID }}' "$workflow"
require 'TF_VAR_resource_group_name: ${{ secrets.AZURE_RESOURCE_GROUP }}' "$workflow"
require 'TF_VAR_state_storage_account_name: ${{ secrets.AZURE_STATE_STORAGE_ACCOUNT }}' "$workflow"
require 'TF_VAR_state_container_name: ${{ secrets.AZURE_STATE_CONTAINER }}' "$workflow"
require 'TF_VAR_github_oidc_subject: ${{ secrets.AZURE_GITHUB_OIDC_SUBJECT }}' "$workflow"
require 'tofu init -input=false -no-color' "$workflow"
require 'tofu plan -input=false -no-color -json | bash scripts/cost-guard.sh /dev/stdin' "$workflow"
require 'statuses=("${PIPESTATUS[@]}")' "$workflow"
for summary in allow deny 'plan failure' undecidable; do
  require "echo \"${summary}\"" "$workflow"
done
if grep -Eqi 'tofu[[:space:]]+apply|terraform[[:space:]]+apply' .github/workflows/*.yml; then
  printf 'Workflows must not apply infrastructure.\n' >&2
  exit 1
fi

require 'bash scripts/test-cost-guard.sh' .github/workflows/cost-guard.yml
printf 'CI contract checks passed.\n'
