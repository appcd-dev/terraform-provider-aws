#!/usr/bin/env bash
# Regenerate docs/11-script-and-stage-catalog.md from repo sources.
# Run from repo root: make catalog
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-${REPO_ROOT}/docs/11-script-and-stage-catalog.md}"
MIGRATOR="${REPO_ROOT}/agent-pipeline-config/modules/aios-agent-aws-migrator"
CODIFY="${REPO_ROOT}/agent-pipeline-config/modules/aios-agent-governance-codify"
SCRIPTS="${MIGRATOR}/scripts"
SHARED="${REPO_ROOT}/agent-pipeline-config/scripts"

{
  cat <<'HEADER'
<!-- generated: do not edit by hand — run `make catalog` from repo root -->

# 11. Script and stage catalog

Auto-generated index of workflow stages, execute-series templates, runner scripts, and Python helpers. Use this when tracing a failed stage or finding which file to change.

HEADER
  echo "_Auto-generated. Regenerate with \`make catalog\` from repo root._"
  echo
  cat <<'SECTION1'

## Stage traceability matrix

How a Guild stage reaches deterministic code on the runner:

```text
workflows_*.tf stage note → stage_context.tf + *.tftpl → LLM paste execute_series
  → run-destination-stage.sh (destination stages) OR stage-runner.sh directly (discovery)
  → cmd_* in stage-runner.sh → Python helpers
```

Log files for destination stages: `$HOME/.<workflow_run_id>/.work/logs/<stage>.log`

### Discovery workflow (`aws-cloud-discovery`)

| Stage | execute_series template | Runner entry | stage-runner cmd | Key notes / outputs |
| --- | --- | --- | --- | --- |
| `runner-capability-preflight` | `runner-capability-preflight-execute-series.sh.tftpl` | direct `stage-runner.sh preflight` | `cmd_preflight` | `runner_capability_preflight_ok` |
| `cloud2code-scan-aws` | `cloud2code-aws-scan-execute-series.sh.tftpl` | `ensure_cloud2code.sh` + cloud2code | (bootstrap) | `monolith_state_uri`, scan artifacts |
| `ingest-and-split` | `ingest-execute-series-embedded.sh.tftpl` | `stage-runner.sh ingest-and-split` | `cmd_ingest_and_split` | split manifest, `aws/groups/` |
| `registry-and-import-codegen` | (agent + SOP) | `stage-runner.sh registry-scaffold` | `cmd_registry_scaffold` | registry scaffold |
| `shell-converge-matrix` | `converge-execute-series-embedded.sh.tftpl` | `stage-runner.sh hydrate-and-plan-matrix` | `cmd_hydrate_and_plan_matrix` | plan matrix, converge status |
| `orphans-secondary-pipeline` | (spawn orphan workflow) | — | — | hands off to orphan workflow |
| `final-gate-and-memory` | (evidence gate) | — | — | discovery evidence checklist; optional orphan handoff |

Gate and loop stages (`*-blocked-gate`, `*-loop`) are LLM evidence checks; they do not invoke new scripts.

### Azure-only workflow (`azure-migration-pr`)

| Stage | execute_series template | `run-destination-stage.sh` | stage-runner cmd | Key notes / outputs |
| --- | --- | --- | --- | --- |
| `azure-source-fetch` | `azure-source-fetch-execute-series-embedded.sh.tftpl` | `azure-source-fetch` | `cmd_azure_source_fetch` | `source_iac_branch`, `aws/groups/` in work root |
| `azure-migration-blueprint` | `azure-migration-blueprint-execute-series-embedded.sh.tftpl` | `azure-migration-blueprint` | `cmd_azure_migration_blueprint` | `azure/artifacts/migration-blueprint.json` |
| `azure-iac-generate` | `azure-iac-generate-execute-series-embedded.sh.tftpl` | `azure-iac-generate` | `cmd_azure_iac_generate` | `azure_iac_generated=true`, `azure/groups/` |
| `azure-iac-validate` | `azure-iac-validate-execute-series-embedded.sh.tftpl` | `azure-iac-validate` | `cmd_azure_iac_validate` | `azure_plan_status=…` |
| `azure-iac-harden` | `azure-iac-harden-execute-series-embedded.sh.tftpl` | `azure-iac-harden` | `cmd_azure_iac_harden` | `azure_iac_harden_ok=true` |
| `azure-iac-governance-conform` | `azure-iac-governance-conform-execute-series-embedded.sh.tftpl` | `azure-iac-governance-conform` | `cmd_azure_iac_governance_conform` | `azure_iac_governance_ok`, governance artifacts |
| `azure-pr` | `azure-pr-execute-series-embedded.sh.tftpl` | `azure-pr` | `cmd_azure_pr` | `azure_pr_url=…` (gated on governance_ok) |
| `azure-only-final` | (evidence gate) | — | — | evidence checklist |

Loop stages: `azure-iac-loop`, `azure-iac-governance-loop`.

### GCP-only workflow (`gcp-migration-pr`)

| Stage | execute_series template | `run-destination-stage.sh` | stage-runner cmd | Key notes / outputs |
| --- | --- | --- | --- | --- |
| `gcp-source-fetch` | `gcp-source-fetch-execute-series-embedded.sh.tftpl` | `gcp-source-fetch` | `cmd_gcp_source_fetch` | `source_iac_branch`, `aws/groups/` in work root |
| `gcp-migration-blueprint` | `gcp-migration-blueprint-execute-series-embedded.sh.tftpl` | `gcp-migration-blueprint` | `cmd_gcp_migration_blueprint` | `gcp/artifacts/migration-blueprint.json` |
| `gcp-iac-generate` | `gcp-iac-generate-execute-series-embedded.sh.tftpl` | `gcp-iac-generate` | `cmd_gcp_iac_generate` | `gcp_iac_generated=true`, `gcp/groups/` |
| `gcp-iac-validate` | `gcp-iac-validate-execute-series-embedded.sh.tftpl` | `gcp-iac-validate` | `cmd_gcp_iac_validate` | `gcp_plan_status=…` |
| `gcp-iac-harden` | `gcp-iac-harden-execute-series-embedded.sh.tftpl` | `gcp-iac-harden` | `cmd_gcp_iac_harden` | `gcp_iac_harden_ok=true` |
| `gcp-iac-governance-conform` | `gcp-iac-governance-conform-execute-series-embedded.sh.tftpl` | `gcp-iac-governance-conform` | `cmd_gcp_iac_governance_conform` | `gcp_iac_governance_ok`, governance artifacts |
| `gcp-pr` | `gcp-pr-execute-series-embedded.sh.tftpl` | `gcp-pr` | `cmd_gcp_pr` | `gcp_pr_url=…` (gated on governance_ok) |
| `gcp-only-final` | (evidence gate) | — | — | evidence checklist |

Loop stages: `gcp-iac-loop`, `gcp-iac-governance-loop`.

### Orphan workflow (`aws-migrator-orphan-iac-module-authoring`)

| Stage | Runner entry | Notes |
| --- | --- | --- |
| `orphan-intake-classify` | LLM + GitHub tools | classify ungrouped resources |
| `scaffold-validate-module` | LLM + runner shell | bootstrap orphan module |
| `memory-and-handoff` | evidence gate | handoff notes |

### Governance codify workflow (`governance-rules-codify`)

| Stage | execute_series template | Runner entry | Notes |
| --- | --- | --- | --- |
| `rules-intake` | `codify-intake-execute-series.sh.tftpl` | GitHub `execute_series` (no runner) | dual-clone source + target repos |
| `rules-codify` | `codify-branch-execute-series.sh.tftpl` | GitHub tools | write Rego under `rules/` |
| `rules-pr` | `codify-pr-execute-series.sh.tftpl` | GitHub tools | open PR, poll GHA `rules-validate` |

SECTION1

  python3 - "$SCRIPTS" <<'PY'
import re
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
run_dest = (scripts / "run-destination-stage.sh").read_text(encoding="utf-8")
stage_runner = (scripts / "stage-runner.sh").read_text(encoding="utf-8")

print("## `run-destination-stage.sh` cases (auto-extracted)")
print()
print("| Stage case | Log file |")
print("| --- | --- |")
for stage in re.findall(r"^\s+([a-z][a-z0-9-]+)\)", run_dest, re.MULTILINE):
    print(f"| `{stage}` | `.work/logs/{stage}.log` |")
print()

print("## `stage-runner.sh` cmd_* functions (auto-extracted)")
print()
print("| Function | Dispatch name |")
print("| --- | --- |")
for fn in re.findall(r"^cmd_([a-z_]+)\(\)", stage_runner, re.MULTILINE):
    print(f"| `cmd_{fn}` | — |")
for name, fn in re.findall(
    r"^\s+([a-z][a-z0-9-]+)\)\s+cmd_([a-z_]+)",
    stage_runner,
    re.MULTILINE,
):
    if name in {"azure", "gcp"}:
        continue
    print(f"| `cmd_{fn}` | `{name}` |")
PY

  cat <<'SECTION2'

## Script inventory

SECTION2

  echo "| Script | Type | Purpose | Unit test |"
  echo "| --- | --- | --- | --- |"

  python3 - "$SCRIPTS" "$SHARED" <<'PY'
import ast
import sys
from pathlib import Path

scripts_dir = Path(sys.argv[1])
shared_dir = Path(sys.argv[2])

def first_line_doc(path: Path) -> str:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
        doc = ast.get_docstring(tree) or ""
        line = doc.split("\n")[0].strip()
        return line[:120] if line else "(no module docstring)"
    except Exception:
        return "(parse error)"

def test_for(name: str) -> str:
    candidate = scripts_dir / f"test_{name}"
    if candidate.exists():
        return f"`test_{name}`"
    stem = Path(name).stem
    for p in scripts_dir.glob(f"test_{stem}*.py"):
        return f"`{p.name}`"
    return "—"

rows = []

for path in sorted(scripts_dir.glob("*.py")):
    if path.name.startswith("test_"):
        continue
    rows.append((path.name, "Python", first_line_doc(path), test_for(path.name)))

for path in sorted(scripts_dir.glob("*.sh")):
    if path.name.startswith("test_"):
        continue
    purpose = "(shell orchestrator)" if path.name == "stage-runner.sh" else "(shell helper)"
    if path.name == "run-destination-stage.sh":
        purpose = "One-line Guild execute_series entrypoints for destination stages"
    elif path.name == "ensure_cloud2code.sh":
        purpose = "Bootstrap cloud2code CLI on runner when absent"
    elif path.name == "cloud2code-scan-detach.sh":
        purpose = "Detach cloud2code import from the execute_* process group so a 30s tool timeout does not SIGKILL it"
    elif path.name == "workflow-run-id.sh":
        purpose = "Shared workflow id check before interpolating $HOME/.<id>"
    elif path.name == "cloud2code-aws-scan.sh":
        purpose = "Run cloud2code import aws and emit scan sentinels"
    elif path.name == "pack-entry.sh":
        purpose = "Versioned runner entrypoint for preflight, scan, ingest, iac-pr, converge, destination"
    test = test_for(path.name) if path.name.endswith(".sh") else "—"
    if path.name == "ensure_cloud2code.sh":
        test = "`test_ensure_cloud2code.sh`"
    elif path.name == "cloud2code-scan-detach.sh":
        test = "`test_cloud2code_scan_detach.sh`"
    rows.append((path.name, "Shell", purpose, test))

for path in sorted(shared_dir.glob("*.py")):
    rows.append((f"agent-pipeline-config/scripts/{path.name}", "Python", first_line_doc(path), "—"))

for path in sorted(shared_dir.glob("*.sh")):
    label = f"agent-pipeline-config/scripts/{path.name}"
    purpose = "Preload script pack onto aiden-runner" if path.name == "preload-script-pack.sh" else "(shared pipeline script)"
    rows.append((label, "Shell", purpose, "—"))

for name, typ, purpose, test in rows:
    purpose = purpose.replace("|", "\\|")
    print(f"| `{name}` | {typ} | {purpose} | {test} |")
PY

  echo
  echo "## Execute-series template inventory (auto-extracted)"
  echo
  echo "| Template | Module | First line (truncated) |"
  echo "| --- | --- | --- |"

  while IFS= read -r tftpl; do
    rel="${tftpl#${REPO_ROOT}/agent-pipeline-config/modules/}"
    mod="$(echo "$rel" | cut -d/ -f1)"
    first="$(head -n 1 "$tftpl" | cut -c1-100 | tr '|' '/')"
    echo "| \`$(basename "$tftpl")\` | \`${mod}\` | \`${first}\` |"
  done < <(find "${REPO_ROOT}/agent-pipeline-config/modules" -name '*execute-series*.tftpl' | sort)

  cat <<'FOOTER'

## Related docs

- [12. I want to…](12-i-want-to.md) — task-oriented navigation
- [04. Workflows & stages](04-workflows-and-stages.md) — stage DAG and governance loop
- [05. LLM vs scripts](05-llm-vs-scripts.md) — what the model does vs deterministic code
- [09. How to change things](09-how-to-change-things.md) — bump script pack version after edits

FOOTER

} >"$OUT"

echo "Wrote $OUT"
