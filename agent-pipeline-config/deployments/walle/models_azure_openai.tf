# Optional Azure OpenAI model provider (Guild provider_type = "openai").
# Enabled when azure_openai_api_url and azure_openai_api_key are both set.
# Models come only from var.azure_openai_models (default []) — no presets.

locals {
  # nonsensitive: boolean gate only (empty vs set); never used as for_each keys from secret material.
  enable_azure_openai = nonsensitive(trimspace(var.azure_openai_api_url) != "" && trimspace(var.azure_openai_api_key) != "")
}

resource "sg_secret" "azure_openai" {
  count = local.enable_azure_openai ? 1 : 0

  name        = "${var.azure_openai_provider_name}-vault"
  description = "Azure OpenAI credentials for Guild openai-compatible model provider."
  category    = "LLM"
  subcategory = "openai"
  metadata = {
    OPENAI_API_KEY     = var.azure_openai_api_key
    OPENAI_API_URL     = var.azure_openai_api_url
    OPENAI_API_VERSION = var.azure_openai_api_version
  }

  lifecycle {
    precondition {
      condition     = length(var.azure_openai_models) > 0
      error_message = "azure_openai_models must list at least one deployment when azure_openai_api_url and azure_openai_api_key are set."
    }
  }
}

resource "sg_guild_model_provider" "azure_openai" {
  count = local.enable_azure_openai ? 1 : 0

  name            = var.azure_openai_provider_name
  provider_type   = "openai"
  host            = var.azure_openai_api_url
  token_reference = sg_secret.azure_openai[0].name
}

resource "sg_guild_model" "azure_openai" {
  for_each = local.enable_azure_openai ? { for m in var.azure_openai_models : m.name => m } : {}

  name          = each.value.name
  provider_name = sg_guild_model_provider.azure_openai[0].name
  model_id      = each.value.model_id
  good_for_task = each.value.good_for_task
}
