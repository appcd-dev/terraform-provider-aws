#!/usr/bin/env python3
"""Contract: destination IaC validate is parallel, resumable, and pack-version gated."""

from __future__ import annotations

import re
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent
SCRIPTS = MODULE / "scripts"
TEMPLATES = MODULE / "templates"
MAIN_TF = MODULE / "main.tf"
STAGE = SCRIPTS / "stage-runner.sh"
PACK_VERSION = "20260930.05"


def main() -> None:
    stage = STAGE.read_text()
    assert "DEST_VALIDATE_PARALLELISM" in stage
    assert "validate-groups" in stage
    assert "cmd_destination_iac_validate()" in stage
    assert 'cmd_azure_iac_validate() {\n  cmd_destination_iac_validate "$1" azure\n}' in stage
    assert 'cmd_gcp_iac_validate() {\n  cmd_destination_iac_validate "$1" gcp\n}' in stage
    assert "DEST_VALIDATE_RUN_TFLINT" in stage
    assert "validate_resume_skipped=" in stage
    assert "dest_validate_parallelism=" in stage

    for name in (
        "gcp-iac-validate-execute-series-embedded.sh.tftpl",
        "azure-iac-validate-execute-series-embedded.sh.tftpl",
    ):
        body = (TEMPLATES / name).read_text()
        assert "DEST_VALIDATE_PARALLELISM='${dest_validate_parallelism}'" in body, name

    main_tf = MAIN_TF.read_text()
    assert 'dest_validate_parallelism           = "4"' in main_tf
    stage_ver = re.search(r'SCRIPT_PACK_VERSION="([^"]+)"', stage).group(1)
    pack_vers = set(
        re.findall(r'script_pack_version\s*=\s*"([^"]+)"', main_tf)
    )
    assert stage_ver == PACK_VERSION, stage_ver
    assert pack_vers == {PACK_VERSION}, pack_vers

    for wf_name in ("workflows_gcp_only.tf", "workflows_azure_only.tf"):
        wf = (MODULE / wf_name).read_text()
        # Validate stage notes must teach deadline resume via identical re-paste.
        assert "deadline" in wf.lower(), wf_name
        assert "re-paste" in wf.lower(), wf_name
        assert "timeout_seconds=7200" in wf, wf_name

    print("OK: destination validate parallel/resume contract")


if __name__ == "__main__":
    main()
