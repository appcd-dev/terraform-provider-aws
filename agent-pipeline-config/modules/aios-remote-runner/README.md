# aios-remote-runner

Composable Guild **remote runner** registration for [aiden-runner](https://github.com/appcd-dev/stackgen-guild/tree/main/cmd/aiden-runner). Runners long-poll mothership over **outbound HTTPS only** — no inbound firewall rules on the customer network.

Requires StackGen provider **>= 0.1.25** (`sg_remote_runner` install commands: `cli_start_command`, `helm_install_command`, `mothership_url`).

## Modes

| `create_runner` | Behavior |
|-----------------|----------|
| `true` | Creates `sg_remote_runner`; outputs copy-paste CLI / Helm install strings (same as Guild UI). |
| `false` | `data.sg_remote_runner` lookup by `name` (runner must already exist). |

## Usage

```hcl
module "onprem_tofu_runner" {
  source = "github.com/appcd-dev/solutions//modules/aios-remote-runner?ref=main"

  create_runner = true
  name          = "org-tofu-runner"
  description   = "On-prem OpenTofu runner for module validation"
  labels = {
    env = "production"
  }
}

# Deploy the runner (one-time, outside Terraform):
output "helm_install" {
  value     = module.onprem_tofu_runner.helm_install_command
  sensitive = true
}

module "terraform_bot" {
  source = "github.com/appcd-dev/solutions//modules/aios-agent-terraform-bot?ref=main"
  # ...
  remote_runner_name            = module.onprem_tofu_runner.runner_name
  remote_runner_attach_to_agent = true
}
```

Provider `stackgen_url` must be the mothership URL reachable from the runner host (same value embedded in install commands).

## Operator checklist (on-prem)

1. `tofu apply` with `create_runner = true`.
2. Copy `cli_start_command` or `helm_install_command` from outputs (or parent module outputs).
3. Run on the runner host / cluster; confirm runner shows **online** in Guild.
4. Attach runner name on agent modules (`remote_runner_attach_to_agent = true`).

The module does **not** install cloud CLIs on the runner image.

### Mothership secret sync

Pass `typed_secret_refs` / `generic_secret_ref_ids` (vault UUIDs whose metadata is **flat env keys**, e.g. `GIT_TOKEN`, `AWS_ACCESS_KEY_ID`). When `bind_runner_secrets` is true (default), Terraform manages `sg_remote_runner_secrets` so aiden-runner receives merged env on sync (memory-only). Use output **`cli_start_command_with_secrets`** for the recommended start command.

```hcl
module "onprem_tofu_runner" {
  source = "github.com/appcd-dev/solutions//modules/aios-remote-runner?ref=main"

  create_runner = true
  name          = "org-tofu-runner"

  typed_secret_refs = {
    github = sg_secret.runner_git.id
    aws    = sg_secret.runner_aws.id
  }
}
```
