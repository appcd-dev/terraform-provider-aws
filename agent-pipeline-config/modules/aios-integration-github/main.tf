terraform {
  required_version = ">= 1.5"
  required_providers {
    sg = { source = "releases.stackgen.com/stackgen/stackgen", version = ">= 0.1.39, < 0.2.0" }
  }
}

locals {
  create_secret = trimspace(var.existing_secret_id) == "" && trimspace(var.github_token) != ""
  secret_id     = local.create_secret ? sg_secret.github_vault[0].id : var.existing_secret_id
}

# Exactly-one validation: either an inline `github_token` (we create the secret)
# or a reference to a pre-existing `sg_secret` ID (we bind to it). Empty both =
# misconfiguration, both set = ambiguous.
resource "terraform_data" "validate_secret_input" {
  lifecycle {
    precondition {
      condition     = trimspace(var.github_token) != "" || trimspace(var.existing_secret_id) != ""
      error_message = "aios-integration-github requires exactly one of `github_token` or `existing_secret_id` to be set."
    }
    precondition {
      condition     = !(trimspace(var.github_token) != "" && trimspace(var.existing_secret_id) != "")
      error_message = "aios-integration-github cannot accept both `github_token` and `existing_secret_id`; pass only one."
    }
  }
}

resource "sg_secret" "github_vault" {
  count = local.create_secret ? 1 : 0

  name        = "${var.integration_name}-vault"
  description = "GitHub personal access token for SCM integration"
  category    = "SCM"
  subcategory = "github"
  metadata = {
    provider = "github"
    token    = var.github_token
  }
}

resource "sg_guild_integration" "github" {
  name           = var.integration_name
  description    = var.description
  type           = "github"
  scope          = var.scope
  secret_ref_ids = [local.secret_id]
  enabled        = var.enabled

  image = {
    name = var.integration_image
  }

  env = length(var.env) > 0 ? var.env : null
}
