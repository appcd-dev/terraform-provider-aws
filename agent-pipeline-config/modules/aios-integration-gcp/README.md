# AIOS Integration — GCP (live-plan credentials)

Provisions a Vault secret with GCP service account credentials and a containerized GCP MCP integration (`gcloud` CLI).

Vendored from `appcd-dev/solutions` `modules/aios-integration-gcp` for the cloud-migrator AWS→GCP destination path.

## Usage

```hcl
module "gcp_integration" {
  source = "../../modules/aios-integration-gcp"

  integration_name      = "cloud-gcp"
  gcp_credentials_json  = var.gcp_credentials_json
  gcp_project_id        = var.gcp_project_id
  gcp_region            = var.gcp_region
}
```

Pass a **read-oriented** service account key (Viewer / equivalent for `tofu plan` against the target project). The agent never applies migrated GCP IaC.

## What it creates

| Resource | Description |
|----------|-------------|
| `sg_secret` | Vault secret (`GOOGLE_APPLICATION_CREDENTIALS_JSON`, `GCP_PROJECT_ID`, `GCP_REGION`) |
| `sg_guild_integration` | Containerized GCP MCP integration |

For remote-runner `tofu plan`, also create a separate vault secret with the same flat env keys and bind it via `sg_remote_runner_secrets` (`runner_gcp_env_secret_id` on the agent module). MCP attach to the architect agent can stay off if Guild agent PUT hits PARSING issues — live plan only needs the runner env secret.
