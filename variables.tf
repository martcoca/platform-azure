variable "azure_subscription_id" {
  description = "Subscription that holds the landing zone."
  type        = string
}

variable "azure_tenant_id" {
  description = "Entra tenant that owns the subscription."
  type        = string
}

variable "resource_group_name" {
  description = "Pre-existing bootstrap resource group."
  type        = string
  default     = "martcoca-platform"
}

variable "location" {
  description = "The single region this landing zone is locked to."
  type        = string
  default     = "eastus"
}

variable "state_storage_account_name" {
  description = "Pre-existing storage account holding OpenTofu state."
  type        = string
}

variable "state_container_name" {
  description = "Blob container for OpenTofu state."
  type        = string
  default     = "tfstate"
}

variable "github_repository" {
  description = "owner/name of the repository CI runs from, for naming and display only."
  type        = string
  default     = "martcoca/platform-azure"
}

variable "github_oidc_subject" {
  description = <<-DESC
    The exact GitHub OIDC subject permitted to obtain a token for the CI identity.

    This organization emits immutable subject claims, which carry numeric org and repo
    IDs rather than names:

      repo:<owner>@<org-id>/<name>@<repo-id>:ref:refs/heads/main

    A subject written in the mutable `repo:owner/name:ref:...` form will not match, and
    federation fails with an unhelpful authorization error. Copy the value from a real
    token claim rather than composing it by hand.
  DESC
  type        = string

  validation {
    condition     = can(regex("^repo:[^/]+@[0-9]+/[^:]+@[0-9]+:", var.github_oidc_subject))
    error_message = "Subject must use the immutable form: repo:<owner>@<org-id>/<name>@<repo-id>:<claim>."
  }
}
