terraform {
  required_version = ">= 1.5"
  required_providers {
    sg = {
      source  = "releases.stackgen.com/stackgen/stackgen"
      version = ">= 0.1.39, < 0.2.0"
    }
  }
}

locals {
  runner_name = trimspace(var.name)
}

resource "sg_remote_runner" "this" {
  count = var.create_runner ? 1 : 0

  name        = local.runner_name
  description = trimspace(var.description)
  labels      = length(var.labels) > 0 ? var.labels : null
}

data "sg_remote_runner" "existing" {
  count = var.create_runner ? 0 : 1
  name  = local.runner_name
}

locals {
  runner_id = var.create_runner ? sg_remote_runner.this[0].id : data.sg_remote_runner.existing[0].id
  status    = var.create_runner ? sg_remote_runner.this[0].status : data.sg_remote_runner.existing[0].status

  # Count must not depend on secret UUIDs (often unknown until apply); parent sets
  # bind_runner_secrets when refs will be configured.
  bind_secrets = var.bind_runner_secrets
}

resource "sg_remote_runner_secrets" "this" {
  count = local.bind_secrets ? 1 : 0

  # Use stable runner name (plan-time known); API accepts name or server id.
  runner_id                     = local.runner_name
  typed_secret_refs             = var.typed_secret_refs
  generic_secret_ref_ids        = var.generic_secret_ref_ids
  secrets_sync_interval_seconds = var.secrets_sync_interval_seconds
}
