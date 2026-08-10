terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.azure_subscription_id
  tenant_id                       = var.azure_tenant_id
  resource_provider_registrations = "none"
  features {}
}

provider "azuread" {
  tenant_id = var.azure_tenant_id
}
