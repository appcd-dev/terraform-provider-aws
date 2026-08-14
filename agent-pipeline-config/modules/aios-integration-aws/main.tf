terraform {
  required_version = ">= 1.5"
  required_providers {
    sg = {
      source = "releases.stackgen.com/stackgen/stackgen"
      # spawn_contracts / workflow metadata (provider >= 0.1.21).
      version = ">= 0.1.39, < 0.2.0"
    }
  }
}

locals {
  create_secret = trimspace(var.existing_secret_id) == "" && trimspace(var.aws_role_arn) != ""
  secret_id     = local.create_secret ? sg_secret.aws_vault[0].id : var.existing_secret_id
}

resource "terraform_data" "validate_secret_input" {
  lifecycle {
    precondition {
      condition     = trimspace(var.aws_role_arn) != "" || trimspace(var.existing_secret_id) != ""
      error_message = "aios-integration-aws requires exactly one of `aws_role_arn` or `existing_secret_id` to be set."
    }
    precondition {
      condition     = !(trimspace(var.aws_role_arn) != "" && trimspace(var.existing_secret_id) != "")
      error_message = "aios-integration-aws cannot accept both `aws_role_arn` and `existing_secret_id`; pass only one."
    }
  }
}

# =============================================================================
# AWS Integration Module
# =============================================================================
# Creates a Vault secret with AWS role ARN and a containerized MCP integration
# for the AWS CLI. Credentials are resolved JIT from Vault at container launch.

resource "sg_secret" "aws_vault" {
  count = local.create_secret ? 1 : 0

  name        = "${var.integration_name}-vault"
  description = "AWS Role Assumption credentials for ${var.integration_name}"
  category    = "CloudProvider"
  subcategory = "aws"
  metadata = {
    aws_role_arn       = var.aws_role_arn
    aws_region         = var.aws_region
    AWS_DEFAULT_REGION = var.aws_region
  }
}

resource "sg_guild_integration" "aws" {
  name           = var.integration_name
  description    = var.description
  type           = "aws"
  scope          = var.scope
  secret_ref_ids = [local.secret_id]
  enabled        = var.enabled

  image = {
    name = var.integration_image
  }

  env = length(var.env) > 0 ? var.env : null
}
