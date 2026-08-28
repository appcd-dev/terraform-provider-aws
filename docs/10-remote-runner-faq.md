# Remote runner FAQ (Nile-Factory)

Answers for running **Aiden 2.0 / Guild `aiden-runner`** with this repo. This is not the older Aiden 1.0 chart (`aiden-remote-runner` from `registry.devopsnow.io`). Do not mix those install commands.

Checked against Nile-Factory image **`ghcr.io/walmart-stackgen/nile-factory-runner`** (`runner/Dockerfile`, `aiden-runner` 0.2.13, pack `20260813.27`) on 2026-08-28.

How Nile-Factory actually starts the process: after `tofu apply` on `deployments/walle`, run `tofu output -raw remote_runner_cli_start_command` (or the Helm output). That string is the source of truth for mothership URL and runner token.

## Quick answers

| # | Question | Answer |
| --- | --- | --- |
| 1 | Exact Docker image | `ghcr.io/walmart-stackgen/nile-factory-runner` (this repo). Guild stock image is not enough. |
| 2 | Registry | GitHub Container Registry (`ghcr.io`), org `walmart-stackgen` |
| 3 | Pull auth | Authenticated. Private package on a private repo. |
| 4 | Tag to pin | `pack-20260813.27` (script pack) or `sha-…`. Also `aiden-0.2.13`. Do not pin `latest`. |
| 5 | Without Kubernetes? | Yes. Docker or the `aiden-runner` binary is enough. |
| 6 | Kubernetes API only for K8s integration? | Yes. Mothership talk is outbound HTTPS. The API server is only needed if you want in-cluster `kubectl` / Helm RBAC. |
| 7 | `--auto-discover` | Host **CLI binaries** and **MCP configs** on the runner, advertised as `host.available_clis`. Not AWS/Azure/GCP resource discovery. |
| 8 | Azure Container Apps? | Not a supported install path. A always-on container with outbound HTTPS can poll mothership, but you lose Helm RBAC, ServiceAccount kube access, and the copy-paste Helm command. |
| 9 | CPU | Chart ships no request/limit. For Nile-Factory start at **2 vCPU**, **4 vCPU** if you split large tfstate. |
| 10 | Memory | Chart ships no request/limit. For Nile-Factory start at **8 GiB**, **16 GiB** for large monolith state / live plan. |
| 11 | Outbound FQDNs | See [Required outbound FQDNs](#11-required-outbound-fqdns). No inbound ports. |
| 12 | Token rotation | Issue a new `sg_aios_…` runner token, put it in the container/Helm secret, restart. Vault-synced cloud/git secrets refresh on `--secrets-ttl` (default 5m). |
| 13 | Share one token across runners? | No. One token is one runner identity. Pollers will steal each other's tasks. |
| 14 | Singleton? | Yes. One process per registered runner. Helm default `replicaCount: 1`. |

## 1. What is the exact Docker image?

This repo publishes:

```text
ghcr.io/walmart-stackgen/nile-factory-runner
```

Built from [`runner/Dockerfile`](../runner/Dockerfile). It installs the `aiden-runner` **binary** (0.2.13) plus OpenTofu, Cloud2Code, AWS CLI, `gh`, `opa`, `tflint`, Python, and the aws-migrator script pack. `HOME` is `/home/runner`.

Do not run Nile-Factory on `ghcr.io/stackgenhq/aiden-runner` (binary only) or on the stock Guild image unless you add the same tools and pack yourself.

## 2. What registry hosts it?

**GitHub Container Registry**, `ghcr.io/walmart-stackgen`.

The `aiden-runner` **binary** still comes from `https://releases.stackgen.com/binaries/aiden-runner/v0.2.13/` at image build time. Helm chart `aiden-runner` from `appcd-public-releases` can deploy this image if you override `image.repository` / `image.tag`.

## 3. Public or authenticated pull?

**Authenticated.** Nile-Factory is a private repo; the GHCR package is private. `docker login ghcr.io` with a token that can read `Walmart-StackGen` packages.

The upstream `aiden-runner` binary tarball used during **build** is public (`releases.stackgen.com`).

## 4. What tag should be pinned?

Pin **`pack-20260813.27`** (or the current `SCRIPT_PACK_VERSION`) so the baked script pack matches the module.

Also published: `aiden-0.2.13`, `sha-<git>`, `latest` on `main`. Do not pin `latest` in production. Rebuild after every pack bump.

Copy-paste from a fresh apply:

```bash
cd agent-pipeline-config/deployments/walle
tofu output -raw remote_runner_cli_start_command
tofu output -raw remote_runner_helm_install_command
```

Those commands already embed mothership URL and token. Replace `:latest` with `:0.2.13` if the generated Docker line still floats.

## 5. Can the runner operate without Kubernetes?

**Yes.** The daemon is a pull agent. It long-polls mothership over outbound HTTPS. Kubernetes is one place to run the process, not a runtime requirement.

Supported without a cluster:

- `docker run` with `STACKGEN_URL`, `STACKGEN_RUNNER_TOKEN`, optional `AUTO_DISCOVER=true`
- `aiden-runner start --mothership … -t …` from the binary or Homebrew

Nile-Factory docs already say Docker **or** Helm after apply. Workflows only care that Guild shows the runner **online**.

## 6. Is the Kubernetes API only required for Kubernetes integration?

**Yes, for the Guild runner itself.**

| Path | Needs kube-apiserver? |
| --- | --- |
| Register, poll tasks, sync vault env, run shell/`tofu`/`git` | No |
| Helm install that mounts a ServiceAccount and talks to the cluster | Yes (in-cluster config) |
| Kubernetes MCP / `kubectl` against a cluster | Yes, via kubeconfig or in-cluster SA |
| Nile-Factory AWS → Azure/GCP migration | No Kubernetes API. AWS, GitHub, optional Azure/GCP APIs. |

Helm default `rbac.createClusterReadRole=true` grants cluster-wide get/list/watch (no secrets). That is for people who **want** kubectl from the runner. For Nile-Factory on a VM or Docker host, skip Helm RBAC entirely.

Turn cluster RBAC off if the runner must not touch Kubernetes:

```bash
--set rbac.createClusterReadRole=false --set rbac.namespaced.enabled=false
```

Or never install the chart and use Docker.

## 7. What does `--auto-discover` actually discover?

From `aiden-runner start --help`:

> Automatically discover available CLI tools and MCP configurations

It inspects the **runner host**: binaries on PATH (and MCP config files), then advertises them to mothership as capabilities (`host.available_clis` and dedicated CLI tools). Helm README: `ALLOWED_CLIS` filters that advertisement and gates `execute_command`.

Default Helm allowlist:

```text
kubectl,helm,aws,gcloud,az,gh
```

Nile-Factory also needs `tofu` or `terraform`, `jq`, `git`, `tar`, `curl`/`wget`. If you enable the allowlist, add those names or `execute_command` will refuse them.

`--auto-discover` does **not**:

- Scan AWS (that is `cloud2code import aws` in the script pack)
- Enumerate Kubernetes resources for SRE discovery
- Invent MCP servers that are not on disk

Equivalent env used in `docker run` examples: `AUTO_DISCOVER=true`.

## 8. Is ACA supported?

**Not as a productized target.** There is no Azure Container Apps values file, revision strategy, or managed identity story in the Helm chart or Nile-Factory deployments.

What ACA can and cannot do:

- **Can:** run the same image as a container with min replicas = 1, outbound HTTPS, env `STACKGEN_URL` + `STACKGEN_RUNNER_TOKEN`. That is just Docker.
- **Cannot (without extra work):** Helm ServiceAccount RBAC, in-cluster kubeconfig, the generated `helm_install_command`, scale-to-zero (the runner must stay up to poll).

If the goal is Nile-Factory migration only, prefer a VM, ACI with a dedicated replica, AKS with `replicaCount: 1`, or local Docker. If someone insists on ACA, treat it as an unsupported Docker host and test poll + secret sync before any workflow.

## 9. CPU recommendation?

The Helm chart sets `resources: {}`. The commented 100m/128Mi block is generic Helm scaffolding, not a Nile-Factory sizing guide.

Idle poll loop is cheap. Nile-Factory work is not: Cloud2Code import, Python split, `tofu plan`, optional live Azure/GCP plan.

Practical starting point for this repo:

| Workload | CPU |
| --- | --- |
| Online, idle | 0.5–1 vCPU |
| Typical `walle` discovery + destination generate | **2 vCPU** request, **4 vCPU** limit |
| Large monolith tfstate / many groups | **4 vCPU** |

## 10. Memory recommendation?

Same: chart does not set requests/limits.

| Workload | Memory |
| --- | --- |
| Online, idle | 512 MiB–1 GiB |
| Typical Nile-Factory run | **8 GiB** |
| Large state, parallel `tofu`, live plan | **16 GiB** |

OOM during ingest/split is more likely than CPU starvation. Do not size this like a hello-world sidecar.

## 11. Required outbound FQDNs?

The runner needs **egress HTTPS only**. No inbound firewall hole, no public LoadBalancer. Helm Service is ClusterIP for optional metrics on 8080, not for mothership callbacks.

StackGen has not published a single official allowlist for this image. For Nile-Factory, allow at least:

| FQDN / pattern | Why |
| --- | --- |
| `<tenant>.cloud.stackgen.com` (Walmart: `walmart.cloud.stackgen.com`) | Mothership poll, secret sync, task claim |
| `ghcr.io` | Image pull |
| `*.pkg.github.com` / `pkg-containers.githubusercontent.com` | GHCR blob fetch |
| `releases.stackgen.com` | `aiden-runner` and Cloud2Code tarballs; OpenTofu provider `releases.stackgen.com/stackgen/stackgen` |
| `appcd-public-releases.s3.us-east-2.amazonaws.com` | Helm chart index (if you install via Helm) |
| `github.com`, `api.github.com` | Clone + `gh pr` into this repo |
| AWS regional API endpoints (`*.amazonaws.com`, STS, S3, EC2, …) | cloud2code + AWS `tofu plan` |
| `login.microsoftonline.com`, `management.azure.com` (and regional ARM) | Optional Azure Reader live plan |
| `*.googleapis.com`, `accounts.google.com` | Optional GCP live plan |
| Registry.terraform.io / OpenTofu registry | Provider download during `tofu init` on generated roots |

If the host uses an HTTP proxy, the Helm chart can set `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` (see chart README). Put mothership and cloud APIs through that proxy or on `NO_PROXY` as your network team requires.

The binary also tries to create a feature-flag client at startup. If your environment blocks unknown SaaS, capture runner logs on first boot and add whatever host it fails on. That host is not listed in the Helm README.

## 12. Token rotation process?

Two different secrets. Do not rotate them the same way.

**A. Runner token (`STACKGEN_RUNNER_TOKEN` / `--runner-token`, prefix `sg_aios_`)**

1. In Guild, create a replacement token for that `sg_remote_runner` (UI or a new apply that regenerates install commands).
2. Update the Docker env, Helm `runner.token` / existing Secret, or ACA secret.
3. Restart the container/pod so it reconnects with the new token.
4. Confirm status **online**.
5. Treat the old token as dead. Do not leave two processes on different tokens for the same logical runner without deleting the old registration.

Terraform output `cli_start_command` is **sensitive** because it embeds this token. Rotate if it was pasted into chat or tickets.

This is **not** the StackGen user PAT paired-token API (`POST /appcd/api/v1/auth/pairedApiKey`). That API rotates human/automation PATs used by `tofu` (`stackgen_token`), not the runner daemon token.

**B. Vault-synced env (GitHub PAT, AWS keys, `ARM_*`, GCP JSON)**

`sg_remote_runner_secrets` pushes flat env keys into the runner in memory. Refresh TTL is `--secrets-ttl` (default 5m). Nile-Factory module default poll hint is 60s mapped onto that TTL. Rotate those secrets in Vault; the runner picks them up on the next sync. Restart if a key must disappear immediately.

## 13. Can multiple runners share the same token?

**No.** The token is the runner's identity. `aiden-runner start` claims up to `--batch-size` tasks (default 10) per poll. Two processes with the same token race. You get stolen tasks, duplicate work, or silent stalls.

Need more capacity? Register **another** `sg_remote_runner` (new name, new token), attach it to the agent, and split by labels. Do not HPA the same Deployment on one token. Chart autoscaling is off for a reason; `replicaCount` defaults to 1.

## 14. Is the runner expected to be singleton?

**Yes, per registered runner.** Guild describes remote runners as one per environment/VPC. Helm `replicaCount: 1`. Nile-Factory attaches a single runner name to the migrator agent.

High availability means a supervisor that **restarts the same identity** (Kubernetes Deployment with 1 replica, Docker restart policy, systemd). It does not mean two live replicas.

## Nile-Factory install reminder

```bash
cd agent-pipeline-config/deployments/walle
tofu output -raw remote_runner_cli_start_command
# run on a host that can reach walmart.cloud.stackgen.com outbound
# wait until Guild shows online
# script pack is baked in the Nile-Factory image; rebuild after pack bumps
```

Helm equivalent (pin the chart and image together):

```bash
helm upgrade --install aiden-runner \
  --repo https://appcd-public-releases.s3.us-east-2.amazonaws.com/charts/ \
  aiden-runner \
  --version 0.2.13 \
  --set image.repository=ghcr.io/walmart-stackgen/nile-factory-runner \
  --set image.tag=pack-20260813.27 \
  --set 'runner.allowedClis=tofu\,terraform\,jq\,git\,aws\,gh\,python3\,tar\,curl\,wget\,opa\,tflint\,cloud2code' \
  --set runner.mothershipUrl=https://walmart.cloud.stackgen.com \
  --set runner.token='<from tofu output, never commit>' \
  --create-namespace -n aiden-runner
```

Prefer the tofu-generated `helm_install_command` when it exists; it already has the right mothership URL and token.

## Sources

- This repo: [`runner/Dockerfile`](../runner/Dockerfile), `docs/00-quickstart.md`, `aios-agent-aws-migrator` runner notes
- `aiden-runner start --help` (v0.2.13)
