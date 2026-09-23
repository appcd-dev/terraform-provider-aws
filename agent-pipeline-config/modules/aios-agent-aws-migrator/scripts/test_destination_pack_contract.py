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


def _runner_git_env_prefix() -> str:
    match = re.search(
        r'runner_git_env_prefix\s*=\s*"(.*)"\s*$',
        MAIN_TF.read_text(),
        re.MULTILINE,
    )
    assert match, "missing runner_git_env_prefix"
    # Terraform $${ → shell ${
    return match.group(1).replace("$${", "${").replace('\\"', '"')


def main() -> None:
    prefix = _runner_git_env_prefix()
    assert prefix.rstrip().endswith(";"), (
        "runner_git_env_prefix must end with ';' so later env+command are not "
        "swallowed by export (session 55e77bfd bad variable name)"
    )
    assert "export GH_TOKEN=" in prefix
    assert 'export GH_TOKEN="' in prefix or "export GH_TOKEN=" in prefix
    # Old bug: one export listing GH_TOKEN=… GITHUB_TOKEN=… GIT_TERMINAL_PROMPT=0
    # with no trailing semicolon before destination env/bash.
    assert not re.search(
        r'export GH_TOKEN=.*" GITHUB_TOKEN=.*" GIT_TERMINAL_PROMPT=0"?\s*$',
        prefix,
    ), "open-ended multi-assign export returned"

    # Dash must accept prefix + destination-shaped suffix (session 55e77bfd).
    probe = (
        prefix
        + " SOURCE_PR='53' WORKFLOW_RUN_ID='wf-x' "
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

    pack = PACK_ENTRY.read_text()
    assert "destination)" in pack
    assert "run-destination-stage.sh" in pack
    assert 'pack-entry.sh destination <stage>' in pack or \
        "pack-entry.sh destination <stage>" in pack

    for name in DEST_TEMPLATES:
        body = (TEMPLATES / name).read_text().strip()
        assert "${runner_pack_entry_invoke}" in body, name
        assert " destination " in body, name
        assert "run-destination-stage.sh" not in body, (
            f"{name} must go through pack-entry, not a hardcoded /opt path"
        )
        assert "bash ${script_pack_preload_dir}" not in body, name

    versions = set(
        re.findall(
            r'script_pack_version\s*=\s*"([^"]+)"',
            MAIN_TF.read_text(),
        )
    )
    stage_ver = re.search(
        r'SCRIPT_PACK_VERSION="([^"]+)"',
        (MODULE / "scripts" / "stage-runner.sh").read_text(),
    ).group(1)
    assert versions == {stage_ver}, (versions, stage_ver)
    assert stage_ver == "20260911.21", stage_ver

    print("OK: destination one-liners are dash-safe and pack-entry backed")


if __name__ == "__main__":
    main()
