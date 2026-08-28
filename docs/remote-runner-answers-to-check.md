# Runner answers to check

Draft for review. Confirm or mark wrong. Longer write-up: [10-remote-runner-faq.md](10-remote-runner-faq.md).

Checked on 2026-08-28 against this repo's image (`runner/Dockerfile`, `aiden-runner` 0.2.13, pack `20260813.27`).

- [ ] 1. Exact Docker image
- [ ] 2. Registry
- [ ] 3. Public or authenticated pull
- [ ] 4. Tag to pin
- [ ] 5. Runner without Kubernetes
- [ ] 6. Kubernetes API only for K8s integration
- [ ] 7. What `--auto-discover` discovers
- [ ] 8. ACA supported
- [ ] 9. CPU recommendation
- [ ] 10. Memory recommendation
- [ ] 11. Required outbound FQDNs
- [ ] 12. Token rotation
- [ ] 13. Multiple runners, same token
- [ ] 14. Singleton

---

## 1. What is the exact Docker image?

`ghcr.io/walmart-stackgen/nile-factory-runner`

Built in this repo (`runner/Dockerfile`). Bakes `aiden-runner` 0.2.13 plus tofu, cloud2code, aws, gh, opa, tflint, python3, and the script pack under `/home/runner/.aws-migrator/script-pack/`.

Do not use `ghcr.io/stackgenhq/aiden-runner` (binary only) or the stock Guild image without those tools.

---

## 2. What registry hosts it?

GitHub Container Registry: `ghcr.io` (org `walmart-stackgen`).

The `aiden-runner` binary is downloaded at **build** time from `releases.stackgen.com`.

---

## 3. Public or authenticated pull?

Authenticated. Private GHCR package. `docker login ghcr.io`.

---

## 4. What tag should be pinned?

`pack-20260813.27` (current `SCRIPT_PACK_VERSION`).

Also: `aiden-0.2.13`, `sha-…`. Do not pin `latest`.

---

## 5. Can the runner operate without Kubernetes?

Yes.

Docker or `aiden-runner start` on a VM/laptop is enough. It long-polls mothership over outbound HTTPS. Kubernetes is optional.

---

## 6. Is Kubernetes API only required for Kubernetes integration?

Yes.

Mothership poll, vault secret sync, shell, `tofu`, `git` do not need kube-apiserver.

kube-apiserver is needed only if the process should run `kubectl` in-cluster (Helm ServiceAccount / ClusterRole) or talk to a cluster via kubeconfig.

Nile-Factory AWS → Azure/GCP does not need the Kubernetes API.

---

## 7. What does `--auto-discover` actually discover?

CLIs on PATH and MCP config files on the **runner host**. Those get advertised as `host.available_clis`.

Helm default allowlist: `kubectl,helm,aws,gcloud,az,gh`. If `ALLOWED_CLIS` is set, add `tofu`/`terraform`, `jq`, `git`, etc. or `execute_command` will block them.

It does **not** scan AWS/Azure/GCP. That is `cloud2code` / the script pack.

Env equivalent: `AUTO_DISCOVER=true`.

---

## 8. Is ACA supported?

No first-class support.

No ACA values, identity story, or docs. An always-on ACA replica can run the same image like Docker. You lose Helm RBAC and in-cluster kube access. Do not scale to zero; the runner must stay up to poll.

Prefer VM, Docker, or AKS with `replicaCount: 1`.

---

## 9. CPU recommendation?

Helm chart: `resources: {}` (no official request/limit). Commented 100m is generic Helm, not for this repo.

For Nile-Factory: **2 vCPU** typical, **4 vCPU** for large tfstate split / many `tofu` plans.

---

## 10. Memory recommendation?

Same: chart does not set memory.

For Nile-Factory: **8 GiB** typical, **16 GiB** for large monolith state or live plan.

---

## 11. Required outbound FQDNs?

Egress HTTPS only. No inbound.

| Need | Hosts |
| --- | --- |
| Mothership | `walmart.cloud.stackgen.com` (or your tenant `*.cloud.stackgen.com`) |
| Image pull | `ghcr.io`, GHCR blob hosts (`pkg-containers.githubusercontent.com`) |
| Binaries / provider | `releases.stackgen.com` |
| Helm chart (if used) | `appcd-public-releases.s3.us-east-2.amazonaws.com` |
| Git | `github.com`, `api.github.com` |
| AWS | `*.amazonaws.com` (STS, S3, EC2, …) |
| Azure live plan (optional) | `login.microsoftonline.com`, `management.azure.com` |
| GCP live plan (optional) | `*.googleapis.com` |
| `tofu init` on generated roots | OpenTofu / Terraform provider registries |

StackGen has not published a complete vendor allowlist. First boot may also call a feature-flag endpoint (not in the Helm README). Capture logs if the firewall is deny-by-default.

---

## 12. Token rotation process?

Runner token (`sg_aios_…`, env `STACKGEN_RUNNER_TOKEN`):

1. Issue a new token for that `sg_remote_runner`.
2. Update Docker env / Helm Secret.
3. Restart the container.
4. Confirm **online**. Old token is dead.

`tofu output -raw remote_runner_cli_start_command` embeds this token. Rotate if it was pasted into chat.

This is **not** the user PAT paired-token API (`/appcd/api/v1/auth/pairedApiKey`). That rotates `stackgen_token` for OpenTofu, not the runner daemon.

Vault-synced `GIT_TOKEN` / `AWS_*` / `ARM_*` refresh on `--secrets-ttl` (default 5m). Rotate those in Vault.

---

## 13. Can multiple runners share the same token?

No.

The token is one runner identity. Two processes steal each other's claimed tasks.

Need more capacity: register another runner (new name, new token), attach it, use labels.

---

## 14. Is the runner expected to be singleton?

Yes, per registered runner.

Helm `replicaCount: 1`. Autoscaling off. One live process. Restart the same identity for HA; do not run two replicas on one token.
