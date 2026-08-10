#!/usr/bin/env bash
# Assign the subscription-scoped Deny policy from the committed denylist (ADR-0039).
#
#   apply-policy-denylist.sh <subscription-id> [--apply]
#
# Prints the diff by default; --apply writes it. Requires Owner on the subscription,
# which is a privileged operation rather than a pull request — that trade is the
# documented cost of having a control CI cannot bypass.
#
# The policy is the built-in "Not allowed resource types", whose default effect is Deny.

set -euo pipefail

[[ $# -ge 1 ]] || { printf 'Usage: %s <subscription-id> [--apply]\n' "$0" >&2; exit 2; }

subscription=$1
apply=false
[[ "${2:-}" == "--apply" ]] && apply=true

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
policy_file="${script_dir}/../config/azure-policy-denylist.json"

DEFINITION_ID=6c112d4e-5bc7-47ae-a041-ea2d9dccd749
ASSIGNMENT="${AZURE_POLICY_ASSIGNMENT:-zero-dollar-denylist}"

for c in az jq; do
  command -v "$c" >/dev/null 2>&1 || { printf 'apply-policy-denylist requires %s.\n' "$c" >&2; exit 2; }
done

want=$(jq -c '[.[].azure_type] | sort' "$policy_file")
have=$(az policy assignment show --name "$ASSIGNMENT" --scope "/subscriptions/${subscription}" \
  --query "parameters.listOfResourceTypesNotAllowed.value" -o json 2>/dev/null | jq -c 'sort' 2>/dev/null || echo 'null')

printf 'assignment: %s\n' "$ASSIGNMENT"
if [[ "$have" == "$want" ]]; then
  printf 'live assignment already matches the committed denylist (%s types).\n' "$(jq 'length' <<<"$want")"
  exit 0
fi

if [[ "$have" == "null" ]]; then
  printf 'no live assignment found; it would be created with %s denied types.\n' "$(jq 'length' <<<"$want")"
else
  jq -r -n --argjson w "$want" --argjson h "$have" '
    (($w - $h) | map("  + \(.)")) + (($h - $w) | map("  - \(.)")) | .[]'
fi

if [[ "$apply" != true ]]; then
  printf '\nRe-run with --apply to write this.\n'
  exit 0
fi

params=$(jq -n --argjson types "$want" '{listOfResourceTypesNotAllowed: {value: $types}}')
az policy assignment create --name "$ASSIGNMENT" \
  --scope "/subscriptions/${subscription}" \
  --policy "$DEFINITION_ID" \
  --params "$params" >/dev/null

printf 'applied.\n'
az policy assignment show --name "$ASSIGNMENT" --scope "/subscriptions/${subscription}" \
  --query "{name:name, denied:length(parameters.listOfResourceTypesNotAllowed.value)}" -o json
