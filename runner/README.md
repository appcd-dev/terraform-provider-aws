# Nile-Factory remote runner image

Builds a **self-contained** `aiden-runner` image for this repo. It does not wrap
`ghcr.io/appcd-dev/stackgen-guild-aiden-runner`. Tools and the aws-migrator script
pack are pinned in this tree and published to GHCR from GitHub Actions.

## Image

```text
ghcr.io/walmart-stackgen/nile-factory-runner:<tag>
```

This repository is private, so pulls need `docker login ghcr.io` with a GitHub
identity that can read packages on `Walmart-StackGen/Nile-Factory`.

| Tag | When |
| --- | --- |
| `sha-<git sha>` | Every successful publish |
| `pack-<script_pack_version>` | Matches `SCRIPT_PACK_VERSION` in `stage-runner.sh` (currently `20260910.3`) |
| `aiden-0.2.22` | Pinned `aiden-runner` binary |
| `latest` | Tip of `main` |

Pin `pack-20260827.4` (or the current pack tag) in production for reproducible CLIs. The image still bakes a bootstrap pack; **script changes ship via vault secret sync** after `tofu apply` (see module `remote_runner_script_pack_sync_enabled`, default true).

## What is inside

- `aiden-runner` 0.2.22
- OpenTofu 1.12.5 (`tofu`)
- Cloud2Code 0.5.3
- AWS CLI v2, `gh`, `git`, `jq`, `python3`, `opa`, `tflint`, `curl`/`wget`/`tar`
- User `runner` (uid 1000), `HOME=/home/runner`
- Script pack at `/home/runner/.aws-migrator/script-pack/<version>/` including
  rendered `ingest-bootstrap.sh` (module defaults: decomposer strategy, cap 0)

`aiden-runner` 0.2.22 allows CLIs under `/usr/bin` by default when `ALLOWED_CLIS`
is unset. This image leaves it unset. If you install via the stock Guild Helm
chart, **clear** `runner.allowedClis` (`--set runner.allowedClis=`) so the
binary default applies. The chart’s kubectl/helm allowlist (and any comma-list
you pass) replaces that default and can block `bash` / `tofu` again.

## Local build

From the repo root:

```bash
docker build -f runner/Dockerfile -t nile-factory-runner:local .
```

Smoke:

```bash
docker run --rm nile-factory-runner:local version
```

## Run after `tofu apply`

```bash
docker login ghcr.io
IMAGE=ghcr.io/walmart-stackgen/nile-factory-runner:pack-20260827.4

# Token and mothership URL come from tofu output (sensitive).
# Prefer substituting this image into that command rather than pasting tokens into git.
docker run -d --name nile-factory-runner --restart unless-stopped \
  -e STACKGEN_URL=https://walmart.cloud.stackgen.com \
  -e STACKGEN_RUNNER_TOKEN='<from tofu output>' \
  -e AUTO_DISCOVER=true \
  "$IMAGE"
```

Helm: use the tofu `helm_install_command`, then `--set image.repository=ghcr.io/walmart-stackgen/nile-factory-runner --set image.tag=pack-20260827.4 --set runner.allowedClis=` (empty, so 0.2.22’s `/usr/bin` default applies). Add an imagePullSecret if the cluster cannot pull private GHCR.

`kubectl cp` preload still works if you need to hot-fix the pack without waiting for a rebuild.

## Publish

Workflow [`.github/workflows/publish-runner.yml`](../.github/workflows/publish-runner.yml) builds `linux/amd64` and `linux/arm64` on every run (push to `main`, pull requests, and `workflow_dispatch`). Only non-PR runs push to GHCR.

Versions and checksums live in [`versions.env`](versions.env).
