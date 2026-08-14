# =============================================================================
# Scenario: aws-migrator
# =============================================================================
# Deploys the AWS region discovery and Terraform reverse-IaC validation workflow
# into Demo Workspace. Reuses the existing demo runner plus GitHub/AWS integrations.

terraform {
  required_version = ">= 1.5"
  required_providers {
    sg = {
      source  = "releases.stackgen.com/stackgen/stackgen"
      version = ">= 0.1.39, < 0.2.0"
    }
  }
}

provider "sg" {
  stackgen_url      = var.stackgen_url
  stackgen_token    = var.stackgen_token
  project_id        = var.stackgen_project_id
  adopt_on_conflict = true
}

data "sg_guild_integration" "github" {
  name = var.github_integration_name
}

data "sg_guild_integration" "aws" {
  name = var.aws_integration_name
}

data "sg_remote_runner" "demo" {
  name = var.remote_runner_name
}

module "aws_migrator" {
  source = "../../../modules/aios-agent-aws-migrator"

  name_suffix = var.name_suffix

  model_names             = var.model_names
  non_trivial_model_names = var.non_trivial_model_names
  policy_ids = {
    dangerous_ops = var.dangerous_ops_policy_id
  }

  existing_github_integration_name = data.sg_guild_integration.github.name
  existing_aws_integration_name    = data.sg_guild_integration.aws.name
  extra_agent_integration_names    = var.extra_agent_integration_names

  create_remote_runner          = false
  remote_runner_name            = data.sg_remote_runner.demo.name
  remote_runner_attach_to_agent = true
  runner_git_token              = var.runner_git_token

  default_iac_repository_url = var.default_iac_repository_url
  default_branch             = var.default_branch
  enable_github_webhook      = false
}
