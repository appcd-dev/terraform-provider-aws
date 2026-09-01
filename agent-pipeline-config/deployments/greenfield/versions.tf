terraform {
  required_version = ">= 1.5"

  required_providers {
    sg = {
      source  = "releases.stackgen.com/stackgen/stackgen"
      # 0.1.39+: sg_workflow preserves empty stage_bindings after apply (null vs {}/[]).
      version = ">= 0.1.39, < 0.2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.85"
    }
  }
}
