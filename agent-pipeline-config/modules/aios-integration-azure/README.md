# AIOS Integration — Azure (Reader only)

Provisions an Azure service principal with **Reader** role only, stores credentials in Vault, and creates a containerized Azure CLI MCP integration.

Vendored from `appcd-dev/solutions` `modules/aios-integration-azure` with Storage Account Key Operator removed so migration live-plan uses least privilege (plan/read, never provision).

## Usage

```hcl
module "azure_integration" {
  source = "../../modules/aios-integration-azure"

  integration_name    = "cloud-azure"
  create_azure_reader = true
  app_display_name    = "stackgen-cloud-azure-reader-walle"
}
```

Requires local `azurerm` / `azuread` providers authenticated (for example `az login`) with rights to create an app registration and assign Reader at the subscription (or scoped) level.

## What it creates

| Resource | Description |
|----------|-------------|
| `azuread_application` | Azure AD app registration (or reuses existing) |
| `azuread_service_principal` | Service principal for the app |
| `azuread_application_password` | Client secret for auth |
| `azurerm_role_assignment` | **Reader** only |
| `sg_secret` | Vault secret (`client_id` / `tenant_id` / `client_secret` / `subscription_id`) |
| `sg_guild_integration` | Containerized Azure CLI MCP integration |

For remote-runner `tofu plan`, also create a separate vault secret with flat `ARM_*` keys and bind it via `sg_remote_runner_secrets` — Guild Azure vault keys are not ARM env names.
