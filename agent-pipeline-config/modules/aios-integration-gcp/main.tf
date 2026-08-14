terraform {
  required_providers {
    sg = { source = "releases.stackgen.com/stackgen/stackgen", version = ">= 0.1.39, < 0.2.0" }
  }
}

locals {
  create_secret = trimspace(var.existing_secret_id) == "" && trimspace(var.gcp_credentials_json) != ""
  secret_id     = local.create_secret ? sg_secret.gcp_vault[0].id : var.existing_secret_id
}

resource "terraform_data" "validate_secret_input" {
  lifecycle {
    precondition {
      condition     = trimspace(var.gcp_credentials_json) != "" || trimspace(var.existing_secret_id) != ""
      error_message = "aios-integration-gcp requires exactly one of `gcp_credentials_json` or `existing_secret_id` to be set."
    }
    precondition {
      condition     = !(trimspace(var.gcp_credentials_json) != "" && trimspace(var.existing_secret_id) != "")
      error_message = "aios-integration-gcp cannot accept both `gcp_credentials_json` and `existing_secret_id`; pass only one."
    }
  }
}

# =============================================================================
# GCP Integration Module
# =============================================================================
# Provisions a Vault secret with GCP service account credentials and a
# containerized GCP MCP integration (gcloud CLI + kubectl).

resource "sg_secret" "gcp_vault" {
  count = local.create_secret ? 1 : 0

  name        = "${var.name_prefix}gcp-vault"
  description = "GCP service account credentials for cloud SRE operations"
  category    = "CloudProvider"
  subcategory = "gcp"
  # Vault GCP resolver requires metadata key `value` (SA JSON). Optional
  # project/region keys are stored for operators; Resolve still derives
  # project_id from the JSON key itself.
  metadata = {
    value          = var.gcp_credentials_json
    GCP_PROJECT_ID = var.gcp_project_id
    GCP_REGION     = var.gcp_region
  }
}

resource "sg_guild_integration" "gcp" {
  name           = var.integration_name
  description    = "GCP cloud integration for GKE, Cloud SQL, IAM, and resource management via gcloud CLI."
  type           = "gcp"
  scope          = "PROJECT"
  secret_ref_ids = [local.secret_id]
  enabled        = true

  image = { name = var.integration_image }

  env = length(var.env) > 0 ? var.env : null
}
