#!/usr/bin/env bash
# Mechanically keep the public inputs, secret handoff, and CI safety contract aligned.

set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

# Fixed-string, unanchored: for assertions that really are about text appearing
# *somewhere* in a file rather than about a line existing. Nothing uses it today — every
# structural assertion below was moved to require_line — and anything reaching for it
# again should be sure the thing it checks is not a line.
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

# A fixed-string match is satisfied by a *comment*. Deleting the guard step but leaving a
# line of prose that names it passes `require` and leaves the workflow unguarded — the
# compromised file the obvious check waves through. Structural facts are therefore matched
# as whole lines: a comment begins with `#` after its indent and cannot match.
#
# Copied from ../platform-gcp/scripts/check-ci-contract.sh, which found the defect. The
# three consumers should keep the same shape; diverging here is how the duplication this
# initiative removed grows back.
require_line() {
  local regex=$1 file=$2
  if ! grep -Eq -- "^[[:space:]]*${regex}[[:space:]]*\$" "$file"; then
    printf 'Missing required contract line /%s/ in %s.\n' "$regex" "$file" >&2
    printf 'It must be a real YAML line, not a mention of one in a comment.\n' >&2
    exit 1
  fi
}

for output in client_id tenant_id subscription_id service_principal_object_id resource_group_name state_storage_account_name state_container_name federated_subject; do
  require_line "output \"${output}\" \\{" outputs.tf
  if ! awk "/output \\\"${output}\\\"/,/^}/" outputs.tf \
      | grep -Eq '^[[:space:]]*sensitive   = true[[:space:]]*$'; then
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

require_line 'key              = "platform-azure/landing-zone\.tfstate"' backend.tf
require_line 'use_azuread_auth = true' backend.tf
require_line 'resource_provider_registrations = "none"' versions.tf
require_line 'backend "local" \{\}' config/example/backend_bootstrap_override.tf
require_line '!config/example/backend_bootstrap_override\.tf' .gitignore
require_line 'cp config/example/backend_bootstrap_override\.tf backend_bootstrap_override\.tf' README.md
require_line 'rm backend_bootstrap_override\.tf' README.md

if ! grep -Fq 'REDACTED-' config/example/landing-zone.tfvars; then
  printf 'The public input example must use redacted placeholders.\n' >&2
  exit 1
fi
# Committed GitHub URLs are checked with `git grep`, not ripgrep.
#
# `if rg ...` fails open: where ripgrep is absent the shell returns 127, the branch is
# simply not taken, and this required assertion silently passes. It was passing that way
# on the authoring machine and would do the same on any runner without ripgrep installed.
#
# git grep also matches the requirement more exactly — the rule is about *committed*
# content — and needs no exclusion list for .git, .terraform, or the ignored local
# config, because it only ever searches tracked files.
command -v git >/dev/null 2>&1 || {
  printf 'check-ci-contract requires git to verify committed content.\n' >&2
  exit 2
}
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  printf 'check-ci-contract must run inside the repository work tree.\n' >&2
  exit 2
}
if git grep -nI -e 'https://github\.com/' -- . >/dev/null 2>&1; then
  printf 'Committed GitHub repository URLs are not permitted:\n' >&2
  git grep -nI -e 'https://github\.com/' -- . >&2
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
  require_line "publish ${mapping}" "$helper"
done
require_line 'tofu output -raw "\$output_name" \| gh secret set "\$secret_name" --repo "\$repository"' "$helper"
require_line "printf 'Set %s\\\\n' \"\\\$secret_name\"" "$helper"
require_absent '--body|\$\(tofu output|tofu output.*>|local value' "$helper"

identity=.github/workflows/azure-identity.yml
require_absent 'credential list|\|\|[[:space:]]*echo[[:space:]]+0' "$identity"
require_line '- uses: azure/login@v2' "$identity"
require_line '- name: Assert the signed-in principal is the federated application' "$identity"
require_line 'id-token: write' "$identity"

workflow=.github/workflows/guarded-plan.yml
require_line 'push:' "$workflow"
require_line 'branches: \[main\]' "$workflow"
require_line 'workflow_dispatch:' "$workflow"
# Unanchored on purpose: this forbids the *text*, so even a commented-out pull_request
# trigger fails. Over-matching a forbidden pattern is the safe direction.
require_absent 'pull_request' "$workflow"
require_line 'contents: read' "$workflow"
require_line 'id-token: write' "$workflow"
require_line '- uses: azure/login@v2' "$workflow"
require_line 'tofu_version: 1\.12\.5' "$workflow"
require_line 'tofu_wrapper: false' "$workflow"
require_line 'ARM_USE_OIDC: "true"' "$workflow"
require_line 'ARM_STORAGE_USE_AZUREAD: "true"' "$workflow"
for secret_var in \
  'TF_VAR_azure_subscription_id: \$\{\{ secrets\.AZURE_SUBSCRIPTION_ID \}\}' \
  'TF_VAR_azure_tenant_id: \$\{\{ secrets\.AZURE_TENANT_ID \}\}' \
  'TF_VAR_resource_group_name: \$\{\{ secrets\.AZURE_RESOURCE_GROUP \}\}' \
  'TF_VAR_state_storage_account_name: \$\{\{ secrets\.AZURE_STATE_STORAGE_ACCOUNT \}\}' \
  'TF_VAR_state_container_name: \$\{\{ secrets\.AZURE_STATE_CONTAINER \}\}' \
  'TF_VAR_github_oidc_subject: \$\{\{ secrets\.AZURE_GITHUB_OIDC_SUBJECT \}\}'; do
  require_line "$secret_var" "$workflow"
done
require_line 'tofu init -input=false -no-color \\' "$workflow"
require_line '>"\$RUNNER_TEMP/tofu-init\.log" 2>&1' "$workflow"
# --- the cost guard is consumed, not carried -------------------------------------------
#
# The guard and its denylist live in the released cost-guard action. Three things have to
# hold and none of them is visible from a diff of this file alone: no copy is committed
# here, every workflow uses the same pinned release, and the guard step is still a gate
# rather than a decoration.

for gone in scripts/cost-guard.sh config/cost-guard-denylist.json; do
  if [[ -e "$gone" ]] || git ls-files --error-unmatch "$gone" >/dev/null 2>&1; then
    printf '%s is back. The guard travels with the action; a local copy is the\n' "$gone" >&2
    printf 'duplication that extracting it removed.\n' >&2
    exit 1
  fi
done

pin_file=config/cost-guard-action.txt
[[ -f "$pin_file" ]] || {
  printf 'Missing %s: the cost-guard release pin has no single source.\n' "$pin_file" >&2
  exit 1
}
pin=$(tr -d '[:space:]' < "$pin_file")
if [[ ! "$pin" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@v[0-9]+(\.[0-9]+\.[0-9]+)?$ ]]; then
  printf 'The cost-guard pin must be owner/repo@vN or owner/repo@vN.N.N, not: %s\n' "$pin" >&2
  exit 1
fi
pin_ref="${pin##*@}"

# Every use of the action, in every workflow, must be that exact pin. A branch ref would
# let what is denied change without a commit in this repository.
#
# Anchored, so a commented-out `uses: …@main` is not scanned as if it were a real one.
# `grep -o` used to lift the pin out of the middle of any line, comments included, and
# report a workflow as unpinned on the strength of a line that runs nothing.
guard_uses=0
while IFS= read -r used; do
  [[ -n "$used" ]] || continue
  guard_uses=$((guard_uses + 1))
  if [[ "$used" != "$pin" ]]; then
    printf 'Workflow uses %s but the pin in %s is %s.\n' "$used" "$pin_file" "$pin" >&2
    exit 1
  fi
done < <(grep -hE '^[[:space:]]*uses:[[:space:]]*[A-Za-z0-9._-]+/cost-guard@[^[:space:]]+[[:space:]]*$' \
  .github/workflows/*.yml | sed 's/^[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]*$//')
if [[ "$guard_uses" -eq 0 ]]; then
  printf 'No workflow uses the cost-guard action.\n' >&2
  exit 1
fi

# --- the guarded plan hands the guard a file, and the guard still gates ---------------

require_line 'tofu plan -input=false -no-color -json \\' "$workflow"
require_line '>"\$RUNNER_TEMP/tofu-plan\.json" 2>"\$RUNNER_TEMP/tofu-plan\.err"' "$workflow"
require_line "uses: ${pin//./\\.}" "$workflow"
require_line 'plan: \$\{\{ runner\.temp \}\}/tofu-plan\.json' "$workflow"
require_line 'id: cost-guard' "$workflow"
require_line 'GUARD_OUTCOME: \$\{\{ steps\.cost-guard\.outcome \}\}' "$workflow"
require_line 'GUARD_VERDICT: \$\{\{ steps\.cost-guard\.outputs\.verdict \}\}' "$workflow"
require_line '\[\[ "\$GUARD_OUTCOME" == "success" \]\] \|\| exit 1' "$workflow"
# The four verdicts the job can report. Each is a real line of the reporting step, so each
# is matched as one — the loop this replaced was a fixed-string search that a comment
# naming the verdict would have satisfied.
require_line 'echo "plan failure" >> "\$GITHUB_STEP_SUMMARY"' "$workflow"
require_line 'echo "undecidable" >> "\$GITHUB_STEP_SUMMARY"' "$workflow"
require_line 'allow\)[[:space:]]+echo "allow" >> "\$GITHUB_STEP_SUMMARY"[[:space:]]+;;' "$workflow"
require_line 'deny\)[[:space:]]+echo "deny" >> "\$GITHUB_STEP_SUMMARY"[[:space:]]+;;' "$workflow"
require_line '\*\)[[:space:]]+echo "undecidable" >> "\$GITHUB_STEP_SUMMARY"[[:space:]]+;;' "$workflow"

# The exit code must come from the guard step. Piping into the guard reports the last
# process in the pipeline, which reads a plan that never ran as a clean plan.
require_absent 'cost-guard\.sh|/dev/stdin|PIPESTATUS' "$workflow"
# And the gate must not be excused. continue-on-error on the guard step would leave a
# workflow that looks guarded and is not.
require_absent 'continue-on-error' "$workflow"

# The guard must still run before anything that could change infrastructure. Nothing here
# applies today, and the assertion below keeps it that way; this one additionally pins the
# ordering, so a future apply step cannot be inserted between the plan and the guard.
plan_line=$(grep -nE '^[[:space:]]*tofu plan -input=false -no-color -json' "$workflow" | head -n 1 | cut -d: -f1)
guard_line=$(grep -nE "^[[:space:]]*uses:[[:space:]]*${pin//./\\.}[[:space:]]*\$" "$workflow" | head -n 1 | cut -d: -f1)
if [[ -z "$plan_line" || -z "$guard_line" || "$guard_line" -le "$plan_line" ]]; then
  printf 'The guard step must follow the plan step in %s.\n' "$workflow" >&2
  exit 1
fi
if grep -nEi 'tofu[[:space:]]+(apply|destroy|import|taint|state[[:space:]]+(rm|mv|push))' "$workflow" >/dev/null; then
  printf 'The guarded plan workflow must not change infrastructure.\n' >&2
  exit 1
fi
require_absent 'client-secret|ARM_CLIENT_SECRET' "$workflow"
if grep -Eqi 'tofu[[:space:]]+apply|terraform[[:space:]]+apply' .github/workflows/*.yml; then
  printf 'Workflows must not apply infrastructure.\n' >&2
  exit 1
fi

# --- the demonstration that the consumed action still behaves like the local one -------

cost_guard=.github/workflows/cost-guard.yml
require_line 'permissions:' "$cost_guard"
require_line 'contents: read' "$cost_guard"
require_line "uses: ${pin//./\\.}" "$cost_guard"
# The three exit outcomes, asserted through the action. `undecidable` failing is the one
# most easily lost when moving to a wrapper, so it is named here rather than implied.
require_line "assert 'clean plan'[[:space:]]+'success/allow/0'[[:space:]]+\"\\\$CLEAN\"" "$cost_guard"
require_line "assert 'denied create'[[:space:]]+'failure/deny/1'[[:space:]]+\"\\\$DENIED\"" "$cost_guard"
require_line "assert 'unrecognizable'[[:space:]]+'failure/undecidable/2'[[:space:]]+\"\\\$UNRECOGNIZABLE\"" "$cost_guard"
require_line "assert 'empty plan'[[:space:]]+'failure/undecidable/2'[[:space:]]+\"\\\$EMPTY\"" "$cost_guard"
# The agreement check reads the guard denylist out of the pinned release, at the same ref
# the plan job's action is pinned to.
require_line 'run: bash scripts/check-denylist-agreement\.sh' "$cost_guard"
require_line 'repository: martcoca/cost-guard' "$cost_guard"
require_line "ref: ${pin_ref//./\\.}" "$cost_guard"
require_line 'COST_GUARD_DENYLIST: .+' "$cost_guard"
require_line '- name: The agreement check must fail when Azure Policy has a hole' "$cost_guard"
require_line '- name: The agreement check must fail when Policy covers a type the guard does not' "$cost_guard"
require_line '- name: The agreement check must refuse to pass when it cannot read the guard denylist' "$cost_guard"
# --- this check must actually run -----------------------------------------------------
#
# A contract check nobody invokes is a comment. It was one here until this packet: nothing
# under .github/ ran scripts/check-ci-contract.sh at all, so the gate between a plan and an
# apply was never asked. scripts/test-ci-contract.sh runs this check against the real tree
# as its first scenario, so requiring the tests to run requires this check to run too.
contract_workflow=.github/workflows/guard.yml
require_line 'run: scripts/test-ci-contract\.sh' "$contract_workflow"

printf 'CI contract checks passed.\n'
