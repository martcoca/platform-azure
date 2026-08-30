#!/usr/bin/env bash
# The contract check's own tests.
#
# scripts/check-ci-contract.sh is what stands between a plan and an apply, and every
# assertion it made used to be a fixed-string grep. A fixed-string grep is satisfied by a
# *comment*: delete the guard step, leave a line of prose naming it, and the check reports
# the workflow as guarded while nothing guards it. That is not a thought experiment —
# tests/fixtures/ci-contract/guarded-plan-guard-commented-out.yml is the file, and the
# pre-0010-E01-T06 check passed against it.
#
# So the check now needs a check. Each scenario below builds a throwaway git tree from
# this repository's tracked files, swaps one file, and runs the real
# scripts/check-ci-contract.sh against it. Nothing here re-implements an assertion: a test
# that re-states what the check does proves only that two copies agree.

set -uo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

fixture=tests/fixtures/ci-contract/guarded-plan-guard-commented-out.yml
plan_workflow=.github/workflows/guarded-plan.yml
failed=0
tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

[[ -f "$fixture" ]] || {
  printf 'Missing negative fixture %s.\n' "$fixture" >&2
  exit 1
}

# A copy of the tracked tree, made a git repository of its own because the check uses
# `git grep` and `git ls-files` to reason about committed content.
scratch_tree() {
  local dest="$tmp_root/$1"
  mkdir -p "$dest"
  git ls-files -z | tar -cf - --null -T - 2>/dev/null | tar -xf - -C "$dest"
  git -C "$dest" init -q
  git -C "$dest" add -A
  git -C "$dest" -c user.email=test@invalid -c user.name=test commit -qm scratch
  printf '%s' "$dest"
}

# Runs the real check in a scratch tree and reports its exit code and output.
run_check() {
  local dest=$1
  bash "$dest/scripts/check-ci-contract.sh" >"$tmp_root/out" 2>&1
  printf '%s' "$?"
}

report() {
  local label=$1 outcome=$2
  if [[ "$outcome" == pass ]]; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s\n' "$label" >&2
    sed 's/^/        /' "$tmp_root/out" >&2
    failed=1
  fi
}

# --- 1. the real workflows still satisfy the check ------------------------------------

dest=$(scratch_tree real)
status=$(run_check "$dest")
if [[ "$status" -eq 0 ]]; then
  report 'the real workflows pass the contract check' pass
else
  report "the real workflows pass the contract check (exit $status)" fail
fi

# --- 2. a guard step replaced by a comment must fail ----------------------------------
#
# The scenario the packet exists for.

dest=$(scratch_tree commented)
cp "$fixture" "$dest/$plan_workflow"
status=$(run_check "$dest")
if [[ "$status" -eq 0 ]]; then
  report 'a guard step replaced by a comment fails the check (it PASSED)' fail
else
  report "a guard step replaced by a comment fails the check (exit $status)" pass
  if grep -Fq 'It must be a real YAML line, not a mention of one in a comment.' "$tmp_root/out"; then
    report 'and says the line must be real rather than a mention in a comment' pass
  else
    report 'and says the line must be real rather than a mention in a comment' fail
  fi
fi

# --- 3. the anchored uses: scanner ignores a commented-out pin ------------------------
#
# `grep -o` used to lift `martcoca/cost-guard@main` out of the middle of a comment and
# report the workflow as unpinned on the strength of a line that runs nothing.

dest=$(scratch_tree commented-pin)
printf '      # uses: martcoca/cost-guard@main\n' >> "$dest/$plan_workflow"
status=$(run_check "$dest")
if [[ "$status" -eq 0 ]]; then
  report 'a commented-out uses: @main is not scanned as a real pin' pass
else
  report "a commented-out uses: @main is not scanned as a real pin (exit $status)" fail
fi

# --- 4. ...but a real one is still caught ---------------------------------------------

dest=$(scratch_tree real-unpinned)
{
  printf '      - name: Not the pinned guard\n'
  printf '        uses: martcoca/cost-guard@main\n'
} >> "$dest/$plan_workflow"
status=$(run_check "$dest")
if [[ "$status" -ne 0 ]] && grep -Fq 'but the pin in config/cost-guard-action.txt is' "$tmp_root/out"; then
  report 'a real uses: @main is rejected as unpinned' pass
else
  report 'a real uses: @main is rejected as unpinned' fail
fi

# --- 5. deleting the freshness step must fail the check -------------------------------
#
# The reporter is not a gate, so nothing else notices if it quietly goes away. That is
# precisely why its absence has to be an error rather than a silence.

dest=$(scratch_tree no-freshness)
grep -v 'uses: martcoca/cost-guard/freshness@' "$dest/$plan_workflow" > "$dest/$plan_workflow.tmp"
mv "$dest/$plan_workflow.tmp" "$dest/$plan_workflow"
status=$(run_check "$dest")
if [[ "$status" -ne 0 ]] && grep -Fq 'freshness@v1' "$tmp_root/out"; then
  report 'deleting the freshness step from the plan job fails the check' pass
else
  report "deleting the freshness step from the plan job fails the check (exit $status)" fail
fi

# And the same for the scheduled workflow, whose whole purpose is to run when nobody is
# watching — the one most easily deleted without anyone missing it.

dest=$(scratch_tree no-schedule)
rm -f "$dest/.github/workflows/cost-guard-freshness.yml"
status=$(run_check "$dest")
if [[ "$status" -ne 0 ]]; then
  report 'deleting the scheduled freshness workflow fails the check' pass
else
  report 'deleting the scheduled freshness workflow fails the check (it PASSED)' fail
fi

# --- 7. the narrowed continue-on-error rule still protects the guard ------------------
#
# The blanket ban became a targeted one when the freshness step needed the flag. That is a
# weakening unless the guard is still covered, so this asserts the part that matters.

dest=$(scratch_tree excused-guard)
awk '{ print } /^[[:space:]]*id: cost-guard[[:space:]]*$/ { print "        continue-on-error: true" }' \
  "$dest/$plan_workflow" > "$dest/plan.tmp"
mv "$dest/plan.tmp" "$dest/$plan_workflow"
status=$(run_check "$dest")
if [[ "$status" -ne 0 ]] && grep -Fq 'allowed on the freshness step and nowhere else' "$tmp_root/out"; then
  report 'excusing the guard step with continue-on-error still fails the check' pass
else
  report "excusing the guard step with continue-on-error still fails the check (exit $status)" fail
fi

if [[ "$failed" -ne 0 ]]; then
  printf '\nThe contract check does not hold its own contract.\n' >&2
  exit 1
fi
printf '\nContract check tests passed.\n'
