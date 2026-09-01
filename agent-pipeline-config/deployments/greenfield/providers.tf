provider "sg" {
  stackgen_url      = var.stackgen_url
  stackgen_token    = var.stackgen_token
  project_id        = var.stackgen_project_id
  adopt_on_conflict = true
}

provider "aws" {
  region = var.aws_region
  # Credential chain: AWS_PROFILE / env keys locally; GitHub Actions OIDC in CI.
}

# Authenticate with local Azure CLI (`az login`) or ARM_* / AZURE_* env vars.
# Used only to create the Reader SP + role assignment — never to apply migration IaC.
provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id != "" ? var.azure_subscription_id : null
}

provider "azuread" {}
