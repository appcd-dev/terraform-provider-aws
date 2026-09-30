#!/usr/bin/env python3
"""Destination execute_series one-liners must be dash-safe and pack-entry backed."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent
TEMPLATES = MODULE / "templates"
MAIN_TF = MODULE / "main.tf"
PACK_ENTRY = MODULE / "scripts" / "pack-entry.sh"

DEST_TEMPLATES = [
    "gcp-source-fetch-execute-series-embedded.sh.tftpl",
    "gcp-migration-blueprint-execute-series-embedded.sh.tftpl",
    "gcp-iac-generate-execute-series-embedded.sh.tftpl",
    "gcp-iac-validate-execute-series-embedded.sh.tftpl",
    "gcp-iac-harden-execute-series-embedded.sh.tftpl",
    "gcp-iac-governance-conform-execute-series-embedded.sh.tftpl",
    "gcp-pr-execute-series-embedded.sh.tftpl",
    "azure-source-fetch-execute-series-embedded.sh.tftpl",
    "azure-migration-blueprint-execute-series-embedded.sh.tftpl",
    "azure-iac-generate-execute-series-embedded.sh.tftpl",
    "azure-iac-validate-execute-series-embedded.sh.tftpl",
    "azure-iac-harden-execute-series-embedded.sh.tftpl",
    "azure-iac-governance-conform-execute-series-embedded.sh.tftpl",
    "azure-pr-execute-series-embedded.sh.tftpl",
]


def _tf_string(name: str) -> str:
    match = re.search(
        rf'{name}\s*=\s*"(.*)"\s*$',
        MAIN_TF.read_text(),
        re.MULTILINE,
    )
    assert match, f"missing {name}"
    return match.group(1).replace("$${", "${").replace('\\"', '"')


def _expand_pack_invoke(
    invoke: str,
    *,
    prefix: str,
    hygiene: str,
    pack_version: str,
    preload_dir: str,
    release_repo: str = "Walmart-StackGen/Nile-Factory",
) -> str:
    """Expand terraform ${local.*} / ${trimspace(...)} the way Guild paste resolves them."""
    out = invoke.replace("${local.runner_git_env_prefix}", prefix)
    out = out.replace("${local.runner_aws_cred_hygiene}", hygiene)
    out = out.replace("${local.script_pack_preload_dir}", preload_dir)
    out = out.replace("${local.script_pack_version}", pack_version)
    out = out.replace("${trimspace(var.script_pack_release_repo)}", release_repo)
    assert "${local." not in out, out[:200]
    assert "${trimspace(" not in out, out[:200]
    return out


def main() -> None:
    destination_runner = (MODULE / "scripts" / "run-destination-stage.sh").read_text()
    assert "apply_opa_mechanical_fixes.py" not in destination_runner
    repo_root = MODULE.parents[2]
    for pack_builder in (repo_root / "runner" / "embed-script-pack.sh", repo_root / "runner" / "package-script-pack.sh"):
        builder_text = pack_builder.read_text()
        assert "apply_opa_mechanical_fixes.py" not in builder_text, (
            f"{pack_builder.name} must not package the removed Terraform mutator"
        )
    prefix = _tf_string("runner_git_env_prefix")
    hygiene = _tf_string("runner_aws_cred_hygiene")
    invoke = _tf_string("runner_pack_entry_invoke")
    main_tf = MAIN_TF.read_text()
    pack_version = re.search(
        r'script_pack_version\s*=\s*"([^"]+)"',
        main_tf,
    ).group(1)
    preload_dir = f"/opt/aws-migrator/script-pack/{pack_version}"
    assert prefix.rstrip().endswith(";"), (
        "runner_git_env_prefix must end with ';' so later env+command are not "
        "swallowed by export (session 55e77bfd bad variable name)"
    )
    assert hygiene.rstrip().endswith(";"), hygiene[-40:]
    assert "export GH_TOKEN=" in prefix
    # Session c6cb3339: prefix already ends with `;`; invoke must not add another
    # at the glue point. Case-arm terminators (`;;`) inside pack_entry() are fine.
    assert not invoke.startswith("${local.runner_git_env_prefix};"), invoke
    rest = invoke.replace("${local.runner_git_env_prefix}", "", 1).lstrip()
    assert not rest.startswith(";"), (
        "runner_pack_entry_invoke must not start with ';' after the git prefix "
        f"(glue would become ;;): {rest[:80]!r}"
    )
    assert not re.search(
        r'export GH_TOKEN=.*" GITHUB_TOKEN=.*" GIT_TERMINAL_PROMPT=0"?\s*$',
        prefix,
    ), "open-ended multi-assign export returned"

    # Dash must accept prefix + destination-shaped suffix (session 55e77bfd).
    probe = (
        prefix
        + " export SOURCE_PR='53' WORKFLOW_RUN_ID='wf-x'; "
        + "bash -c 'echo ok SOURCE_PR=$SOURCE_PR'"
    )
    got = subprocess.run(
        ["/bin/sh", "-c", probe],
        check=False,
        capture_output=True,
        text=True,
    )
    assert got.returncode == 0, got.stderr
    assert "ok SOURCE_PR=53" in got.stdout, got.stdout

    # Combined paste as Guild would expand it (session c6cb3339 ;; crash at glue).
    combined = _expand_pack_invoke(
        invoke,
        prefix=prefix,
        hygiene=hygiene,
        pack_version=pack_version,
        preload_dir=preload_dir,
    )
    glue = prefix.rstrip()[-1] + combined[len(prefix) : len(prefix) + 2]
    assert ";;" not in glue, f"prefix+invoke glue produced ;;: {glue!r} / {combined[:120]!r}"
    # Syntax-check under dash (/bin/sh on Ubuntu CI). Use `sh -n` so missing
    # /opt pack or gh does not fail the contract; we only care about paste shape.
    got2 = subprocess.run(
        ["/bin/sh", "-n", "-c", f"export SOURCE_PR='53'; {combined} destination gcp-source-fetch 'wf-x'"],
        check=False,
        capture_output=True,
        text=True,
    )
    assert got2.returncode == 0, got2.stderr
    assert "Syntax error" not in (got2.stderr or ""), got2.stderr

    # Discovery entrypoint arguments must be promoted into the environment before
    # the generated bootstraps run. execute_series passes argv to pack_entry; it
    # does not export WORKFLOW_RUN_ID on behalf of the command.
    for stage in ("ingest", "iac-pr", "converge"):
        assert (
            f';; {stage}) export WORKFLOW_RUN_ID="${{2}}"; shift; exec bash'
            in invoke
        ), f"{stage} dispatch must export the positional workflow run id"

    pack = PACK_ENTRY.read_text()
    assert "destination)" in pack
    assert "run-destination-stage.sh" in pack
    assert "pack-entry.sh destination <stage>" in pack

    for name in DEST_TEMPLATES:
        body = (TEMPLATES / name).read_text().strip()
        assert body.startswith("export "), f"{name} must export env for pack-entry child"
        assert "${runner_pack_entry_invoke}" in body, name
        assert " destination " in body, name
        assert "run-destination-stage.sh" not in body, (
            f"{name} must go through pack-entry, not a hardcoded /opt path"
        )
        assert "bash ${script_pack_preload_dir}" not in body, name

    versions = set(
        re.findall(
            r'script_pack_version\s*=\s*"([^"]+)"',
            main_tf,
        )
    )
    stage_ver = re.search(
        r'SCRIPT_PACK_VERSION="([^"]+)"',
        (MODULE / "scripts" / "stage-runner.sh").read_text(),
    ).group(1)
    assert versions == {stage_ver}, (versions, stage_ver)
    assert stage_ver == pack_version, stage_ver

    stage_context = (MODULE / "stage_context.tf").read_text()
    for stage in ("gcp_source_fetch", "gcp_pr"):
        match = re.search(
            rf"dbsplit_spawn_context_{stage}\s*=\s*<<-EOT(.*?)\nEOT",
            stage_context,
            re.DOTALL,
        )
        assert match, f"missing spawn context for {stage}"
        assert "timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}" in match.group(1), (
            f"{stage} execute_series must inherit the configured runner timeout"
        )

    gcp_workflow = (MODULE / "workflows_gcp_only.tf").read_text()
    assert "set `timeout_seconds=3600`" in gcp_workflow
    assert "the 30-second default killed this stage" in gcp_workflow

    dest = (MODULE / "scripts" / "run-destination-stage.sh").read_text()
    assert 'NILE_RULES_REF="${NILE_RULES_REF:-main}"' in dest, (
        "run-destination-stage must default NILE_RULES_REF to a live ref"
    )
    assert "20260827033726" not in dest

    print("OK: destination one-liners are dash-safe and pack-entry backed")


if __name__ == "__main__":
    main()
