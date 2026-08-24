# Azure landing zone

Per-cloud Azure landing zone for keyless GitHub Actions federation, remote OpenTofu
state, and zero-cost guardrails.

This root provides an Azure landing zone with provider-native cost controls, keyless
GitHub Actions federation, and remote OpenTofu state.

## Azure cannot be capped, so it is fenced instead

Pay-as-you-go subscriptions have no spending limit. Microsoft is explicit that the
limit is unavailable on pay-as-you-go and is removed when a trial converts, which every
trial does. Budgets alert; they do not stop anything.

Azure does, however, have a control the other two clouds lack: **Azure Policy can refuse
resource types server-side.** A denied type cannot be created by any route — portal,
CLI, or OpenTofu — and the portal greys it out. That is strictly stronger than a CI
guard, which is bypassed by not running CI.

So this landing zone inverts the usual order:

| Control | Strength | Where |
|---|---|---|
| Azure Policy `Deny` on 13 resource types | server-side, unbypassable | subscription scope |
| CI cost guard | fails a plan before apply, with a named resource and price | `martcoca/cost-guard@v1.0.0` |
| Scale-to-zero architecture | nothing standing to bill | consuming repositories |
| Budget alerting at $0.01 actual, $1.00 forecast | notification only | subscription scope |

The reasoning is recorded in ADR-0039 in the doctrine repository.

### The two denylists are one list

`config/azure-policy-denylist.json` drives Azure Policy. The guard denylist is not in
this repository at all: it travels with the released cost-guard action, pinned once in
`config/cost-guard-action.txt`. A type denied in one and permitted by the other is a
hole that gets found by accident, so agreement is a test rather than a convention:

```bash
scripts/check-denylist-agreement.sh
```

With no arguments it fetches the guard denylist from the pinned release with `gh`. CI
instead checks that release out and points the script at it:

```bash
COST_GUARD_DENYLIST=<checkout>/config/cost-guard-denylist.json scripts/check-denylist-agreement.sh
```

Either way the comparison is against the release CI actually runs, never against a local
copy — there is none to be stale. If the denylist cannot be read the check exits 2 rather
than reporting agreement it did not perform.

It runs in CI on every push, in both directions — Policy types absent from the guard,
and `azurerm_*` guard types absent from Policy. `--live` additionally diffs the
committed file against the real assignment, so drift applied by hand is caught too.

`scripts/apply-policy-denylist.sh <subscription-id>` prints the diff between the
committed list and the live assignment; `--apply` writes it. Assignment needs Owner on
the subscription, so changing the denylist is deliberately not a pull request.

## What this root creates

- An Entra application and service principal for GitHub Actions, with **no client
  secret resource anywhere in this root**.
- A federated identity credential accepting exactly one OIDC subject.
- `Contributor` scoped to the one resource group — never the subscription, so CI cannot
  reach the Policy assignment or the budget that constrain it.
- `Storage Blob Data Contributor` scoped to the state account alone.
- The blob container holding OpenTofu state.

The resource group and storage account are bootstrap resources, created once by hand
because this root cannot store its own state until they exist. They are read here as
data sources.

## The OIDC subject must be the immutable form

This organization emits immutable subject claims, which carry numeric organization and
repository IDs instead of names:

```
repo:<owner>@<org-id>/<name>@<repo-id>:ref:refs/heads/main
```

The familiar `repo:owner/name:ref:...` form **will not match**, and the failure surfaces
as a generic authorization error that reads like a permissions problem and is not one.
This cost real time on `platform-aws`; `variables.tf` validates the shape so it cannot
be reintroduced silently. Read the value from an actual token claim rather than
composing it by hand.

## State storage has no keys

The storage account is created with `allowSharedKeyAccess=false` — the Azure equivalent
of GCP's zero service-account keys. Every access is Entra ID. Consequently the backend
must set `use_azuread_auth = true`; there is no account key to fall back to, and
omitting it fails with a confusing authentication error.

Blob versioning is enabled, public blob access is off, and the minimum TLS version is
1.2.

## Inputs

Copy `config/example/landing-zone.tfvars` to the ignored
`config/local/landing-zone.tfvars` and replace every redacted marker. No subscription,
tenant, organization, or repository ID belongs in a tracked file.

## First run

The state container is created by this root, so the first apply runs on local state and
is then migrated. In a fresh checkout, first copy the tracked bootstrap template to the
ignored root override:

```bash
cp config/example/backend_bootstrap_override.tf backend_bootstrap_override.tf
tofu init
tofu apply -var-file=config/local/landing-zone.tfvars
rm backend_bootstrap_override.tf
tofu init \
  -backend-config="resource_group_name=<resource group>" \
  -backend-config="storage_account_name=<state storage account>" \
  -backend-config="container_name=tfstate" \
  -migrate-state
```

Applying this root creates identity and role assignments, which are human-reserved work
under ADR-0021. An agent prepares and plans it; a human applies it.

## CI contract

After the human apply and state migration, transfer the workflow values without printing
them with:

```bash
scripts/publish-github-secrets.sh <owner/repository>
```

The helper sets only these repository secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_STATE_STORAGE_ACCOUNT`,
`AZURE_STATE_CONTAINER`, and `AZURE_GITHUB_OIDC_SUBJECT`.

The guarded plan runs only on pushes to `main` and manual dispatch. It authenticates with
OIDC, runs a guarded plan, and never applies. The post-apply live evidence still needed
is the human credential-inventory check and successful identity and guarded-plan workflow
runs.

## Local checks

Run these without cloud authentication:

```bash
tofu fmt -check -recursive .
tofu validate
scripts/check-denylist-agreement.sh
scripts/check-ci-contract.sh
scripts/test-ci-contract.sh
```

## A fresh subscription registers nothing

Azure reports an unregistered resource provider as `SubscriptionNotFound`, which sends
you looking for the wrong problem entirely. If a create fails that way, check
registration first:

```bash
az provider register --namespace Microsoft.Storage --wait
```
