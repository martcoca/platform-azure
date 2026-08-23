#!/usr/bin/env bash
# Assert the two denylists agree (ADR-0039).
#
# Azure has two cost controls that deny the same things by different mechanisms: an Azure
# Policy assignment that refuses resource types server-side, and the CI cost guard that
# refuses OpenTofu resource types before apply. ADR-0039 requires them to stay in
# agreement, and a requirement stated only in prose drifts. This makes it a test.
#
# The guard denylist is no longer a file in this repository. It travels with the released
# cost-guard action, and a second copy here would be exactly the duplication that
# extracting the guard removed. So it is *supplied*, never assumed:
#
#   COST_GUARD_DENYLIST=<path>               compare against that file. CI sets it to a
#                                            checkout of the pinned release, so the
#                                            comparison uses the same bytes the plan job's
#                                            guard uses.
#   (unset)                                  fetch the denylist from the release pinned in
#                                            config/cost-guard-action.txt, using `gh`.
#
# There is no third path, and in particular no fallback to "assume they agree". If the
# guard denylist cannot be read this exits 2 — could not check. A check that reports
# agreement it never performed is worse than no check at all.
#
#   check-denylist-agreement.sh              compare the Policy file against the release
#   check-denylist-agreement.sh --live       also compare against the live assignment
#
# --live needs an authenticated `az` and reads the assignment named by
# AZURE_POLICY_ASSIGNMENT (default zero-dollar-denylist). It reads only; it changes
# nothing.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
policy_file="${script_dir}/../config/azure-policy-denylist.json"
pin_file="${script_dir}/../config/cost-guard-action.txt"

command -v jq >/dev/null 2>&1 || {
  printf 'check-denylist-agreement requires jq.\n' >&2
  exit 2
}

[[ -f "$policy_file" ]] || {
  printf 'Missing denylist: %s\n' "$policy_file" >&2
  exit 2
}

fetched=""
cleanup() { [[ -n "$fetched" ]] && rm -f "$fetched"; return 0; }
trap cleanup EXIT

guard_file="${COST_GUARD_DENYLIST:-}"
guard_source="COST_GUARD_DENYLIST=${guard_file}"

if [[ -z "$guard_file" ]]; then
  [[ -f "$pin_file" ]] || {
    printf 'Missing %s; cannot tell which cost-guard release to compare against.\n' \
      "$pin_file" >&2
    exit 2
  }
  pin=$(tr -d '[:space:]' < "$pin_file")
  slug="${pin%@*}"
  ref="${pin##*@}"
  if [[ -z "$slug" || -z "$ref" || "$slug" == "$pin" ]]; then
    printf 'Malformed action pin in %s: %s\n' "$pin_file" "$pin" >&2
    exit 2
  fi

  command -v gh >/dev/null 2>&1 || {
    printf 'The guard denylist lives in the %s release, not in this repository.\n' "$pin" >&2
    printf 'Set COST_GUARD_DENYLIST to a checkout of it, or install gh to fetch it.\n' >&2
    exit 2
  }

  fetched=$(mktemp)
  if ! gh api -H 'Accept: application/vnd.github.raw' \
      "repos/${slug}/contents/config/cost-guard-denylist.json?ref=${ref}" \
      >"$fetched" 2>/dev/null; then
    printf 'Could not fetch the guard denylist from %s; refusing to report agreement.\n' \
      "$pin" >&2
    exit 2
  fi
  guard_file="$fetched"
  guard_source="$pin"
fi

[[ -f "$guard_file" ]] || {
  printf 'Missing guard denylist: %s\n' "$guard_file" >&2
  printf 'Refusing to report agreement against a denylist that is not there.\n' >&2
  exit 2
}

# An unreadable or empty denylist must not compare equal to anything. Both comparisons
# below iterate the guard list, so an empty array would silently satisfy one direction.
jq -e 'type == "array" and length > 0' "$guard_file" >/dev/null 2>&1 || {
  printf 'The guard denylist at %s is not a non-empty JSON array.\n' "$guard_file" >&2
  exit 2
}

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

printf 'Denylists agree (guard denylist from %s).\n' "$guard_source"
