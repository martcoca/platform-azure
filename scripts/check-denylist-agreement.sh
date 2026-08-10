#!/usr/bin/env bash
# Assert the two denylists agree (ADR-0039).
#
# Azure has two cost controls that deny the same things by different mechanisms: an Azure
# Policy assignment that refuses resource types server-side, and the CI cost guard that
# refuses OpenTofu resource types before apply. ADR-0039 requires them to stay in
# agreement, and a requirement stated only in prose drifts. This makes it a test.
#
#   check-denylist-agreement.sh              compare the two committed files
#   check-denylist-agreement.sh --live       also compare against the live assignment
#
# --live needs an authenticated `az` and reads the assignment named by
# AZURE_POLICY_ASSIGNMENT (default zero-dollar-denylist). It reads only; it changes
# nothing.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
policy_file="${script_dir}/../config/azure-policy-denylist.json"
guard_file="${script_dir}/../config/cost-guard-denylist.json"

command -v jq >/dev/null 2>&1 || {
  printf 'check-denylist-agreement requires jq.\n' >&2
  exit 2
}

for f in "$policy_file" "$guard_file"; do
  [[ -f "$f" ]] || { printf 'Missing denylist: %s\n' "$f" >&2; exit 2; }
done

failed=0

note() {
  printf '%s\n' "$1" >&2
  failed=1
}

# 1. Every OpenTofu type the Policy claims to cover must be denied by the guard, so a
#    plan fails with a named cost rather than surviving CI and dying at deploy time.
missing_from_guard=$(jq -r -n \
  --slurpfile policy "$policy_file" \
  --slurpfile guard "$guard_file" '
    ($guard[0] | map(.resource_type)) as $guarded
    | $policy[0][]
    | .azure_type as $azure
    | .tofu_types[]
    | select(. as $t | $guarded | index($t) | not)
    | "  \(.) (covered by Policy as \($azure))"
  ')

if [[ -n "$missing_from_guard" ]]; then
  note "Denied by Azure Policy but absent from the cost guard:"
  note "$missing_from_guard"
fi

# 2. Every azurerm_* type the guard denies must be covered by the Policy, or the stronger
#    server-side control has a hole the weaker one pretends is closed.
missing_from_policy=$(jq -r -n \
  --slurpfile policy "$policy_file" \
  --slurpfile guard "$guard_file" '
    ([$policy[0][].tofu_types[]]) as $covered
    | $guard[0][]
    | select(.resource_type | startswith("azurerm_"))
    | select(.resource_type as $t | $covered | index($t) | not)
    | "  \(.resource_type) (\(.resource), \(.monthly_cost))"
  ')

if [[ -n "$missing_from_policy" ]]; then
  note "Denied by the cost guard but not by Azure Policy:"
  note "$missing_from_policy"
fi

if [[ "${1:-}" == "--live" ]]; then
  assignment="${AZURE_POLICY_ASSIGNMENT:-zero-dollar-denylist}"
  command -v az >/dev/null 2>&1 || {
    printf 'check-denylist-agreement --live requires the az CLI.\n' >&2
    exit 2
  }

  live=$(az policy assignment show --name "$assignment" \
    --query "parameters.listOfResourceTypesNotAllowed.value" -o json 2>/dev/null || true)

  if [[ -z "${live//[[:space:]]/}" || "$live" == "null" ]]; then
    note "Could not read live policy assignment '$assignment'; refusing to report agreement."
  else
    drift=$(jq -r -n --argjson live "$live" --slurpfile policy "$policy_file" '
      ($policy[0] | map(.azure_type) | sort) as $want
      | ($live | sort) as $have
      | (($want - $have) | map("  only in the committed file: \(.)"))
        + (($have - $want) | map("  only on the live assignment: \(.)"))
      | .[]
    ')
    if [[ -n "$drift" ]]; then
      note "Live assignment '$assignment' does not match the committed policy denylist:"
      note "$drift"
    fi
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  printf '\nThe denylists disagree. ADR-0039 requires one list expressed two ways.\n' >&2
  exit 1
fi

printf 'Denylists agree.\n'
