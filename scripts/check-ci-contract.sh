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

require_absent() {
  local pattern=$1
  local file=$2
  if grep -Eq -- "$pattern" "$file"; then
    printf 'Forbidden contract text in %s: %s\n' "$file" "$pattern" >&2
    exit 1
  fi
}

for output in client_id tenant_id subscription_id service_principal_object_id resource_group_name state_storage_account_name state_container_name federated_subject; do
  require "output \"${output}\"" outputs.tf
  if ! awk "/output \\\"${output}\\\"/,/^}/" outputs.tf | grep -Fq 'sensitive   = true'; then
    printf 'Output %s must be sensitive.\n' "$output" >&2
    exit 1
  fi
done

if grep -Fq 'github_repository' variables.tf main.tf config/example/landing-zone.tfvars; then
  printf 'github_repository must not duplicate the authoritative OIDC subject.\n' >&2
  exit 1
fi
if awk '/variable "resource_group_name"/,/^}/' variables.tf | grep -Fq 'default'; then
  printf 'resource_group_name must be required.\n' >&2
  exit 1
fi

require 'key              = "platform-azure/landing-zone.tfstate"' backend.tf
require 'use_azuread_auth = true' backend.tf
require 'resource_provider_registrations = "none"' versions.tf
require 'backend "local" {}' config/example/backend_bootstrap_override.tf
require '!config/example/backend_bootstrap_override.tf' .gitignore
require 'cp config/example/backend_bootstrap_override.tf backend_bootstrap_override.tf' README.md
require 'rm backend_bootstrap_override.tf' README.md

if ! grep -Fq 'REDACTED-' config/example/landing-zone.tfvars; then
  printf 'The public input example must use redacted placeholders.\n' >&2
  exit 1
fi
if rg -n --hidden --glob '!.git/**' --glob '!.agentic/**' --glob '!config/local/**' --glob '!.terraform/**' 'https://github\.com/' . >/dev/null; then
  printf 'Committed GitHub repository URLs are not permitted.\n' >&2
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
require 'printf '\''Set %s\n'\'' "$secret_name"' "$helper"
require_absent '--body|\$\(tofu output|tofu output.*>|local value' "$helper"

identity=.github/workflows/azure-identity.yml
require_absent 'credential list|\|\|[[:space:]]*echo[[:space:]]+0' "$identity"
require 'uses: azure/login@v2' "$identity"
require 'Assert the signed-in principal is the federated application' "$identity"
require 'id-token: write' "$identity"

workflow=.github/workflows/guarded-plan.yml
require 'push:' "$workflow"
require 'branches: [main]' "$workflow"
require 'workflow_dispatch:' "$workflow"
require_absent 'pull_request' "$workflow"
require 'contents: read' "$workflow"
require 'id-token: write' "$workflow"
require 'uses: azure/login@v2' "$workflow"
require 'tofu_version: 1.12.5' "$workflow"
require 'tofu_wrapper: false' "$workflow"
require 'ARM_USE_OIDC: "true"' "$workflow"
require 'ARM_STORAGE_USE_AZUREAD: "true"' "$workflow"
for secret_var in \
  'TF_VAR_azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}' \
  'TF_VAR_azure_tenant_id: ${{ secrets.AZURE_TENANT_ID }}' \
  'TF_VAR_resource_group_name: ${{ secrets.AZURE_RESOURCE_GROUP }}' \
  'TF_VAR_state_storage_account_name: ${{ secrets.AZURE_STATE_STORAGE_ACCOUNT }}' \
  'TF_VAR_state_container_name: ${{ secrets.AZURE_STATE_CONTAINER }}' \
  'TF_VAR_github_oidc_subject: ${{ secrets.AZURE_GITHUB_OIDC_SUBJECT }}'; do
  require "$secret_var" "$workflow"
done
require 'tofu init -input=false -no-color' "$workflow"
require '>"$RUNNER_TEMP/tofu-init.log" 2>&1' "$workflow"
require 'tofu plan -input=false -no-color -json 2>"$RUNNER_TEMP/tofu-plan.err" | bash scripts/cost-guard.sh /dev/stdin' "$workflow"
require '>"$RUNNER_TEMP/cost-guard.out" 2>"$RUNNER_TEMP/cost-guard.err"' "$workflow"
require 'statuses=("${PIPESTATUS[@]}")' "$workflow"
for verdict in allow deny 'plan failure' undecidable; do
  require "echo \"${verdict}\" >> \"\$GITHUB_STEP_SUMMARY\"" "$workflow"
done
require_absent 'client-secret|ARM_CLIENT_SECRET' "$workflow"
if grep -Eqi 'tofu[[:space:]]+apply|terraform[[:space:]]+apply' .github/workflows/*.yml; then
  printf 'Workflows must not apply infrastructure.\n' >&2
  exit 1
fi

cost_guard=.github/workflows/cost-guard.yml
require 'permissions:' "$cost_guard"
require 'contents: read' "$cost_guard"
require 'bash scripts/test-cost-guard.sh' "$cost_guard"
printf 'CI contract checks passed.\n'
