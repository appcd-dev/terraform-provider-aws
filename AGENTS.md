# AGENTS.md

## Repo purpose
<!-- markdownlint-disable first-line-h1 no-inline-html --> <a href="https://terraform.io">   <picture>     <source media="(prefers-color-scheme: dark)" srcset=".github/terraform_logo_dark.svg">     <source media="(prefers-color-scheme: light)" srcset=".github/terraform_logo_light.svg">     <img src=".github/terraform_logo_light.svg" alt="Terraform logo" title="Terraform" align="right" height="50">

## Tech stack
- Go

## Build / test / lint / run (best-effort)

### Bootstrap
- (not detected; check README/Makefile/package scripts)

### Build
- `go build ./...`

### Test
- `go test ./...`

### Lint / format
- `golangci-lint run  # if configured`

### Run
- (not detected; check README/Makefile/package scripts)

## Project layout (where to look)
- Start with `README.md` and `.github/workflows/`.
- Common conventions (if present): `src/`, `lib/`, `cmd/`, `internal/`, `packages/`.
- Look for build entrypoints: `Makefile`, `package.json`, `go.mod`, `pyproject.toml`.

## CI / workflows
- `acctest-terraform-embedded-lint.yml`
- `acctest-terraform-lint.yml`
- `changelog_misspell.yml`
- `comments.yml`
- `copyright.yml`
- `dependencies.yml`
- `documentation.yml`
- `examples.yml`
- `firewatch.yml`
- `gen-teamcity.yml`
- `generate_changelog.yml`
- `golangci-lint.yml`
- `goreleaser-ci.yml`
- `lock.yml`
- `maintainer_helpers.yml`
- `milestone.yml`
- `mkdocs.yml`
- `post_publish.yml`
- `provider.yml`
- `providerlint.yml`
- `pull_request_review.yml`
- `release.yml`
- `resource-counts.yml`
- `semgrep-ci.yml`
- `skaff.yml`
- `snapshot.yml`
- `stale.yml`
- `triage.yml`
- `website.yml`
- `workflow-lint.yml`
- `yamllint.yml`

## Common gotchas
- Some commands above are **best-effort guesses** based on repository signals; prefer README/Makefile/package scripts when they disagree.
- If CI fails, check workflow logs for exact tool versions and required secrets.
