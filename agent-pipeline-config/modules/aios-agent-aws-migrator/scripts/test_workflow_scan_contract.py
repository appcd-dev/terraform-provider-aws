#!/usr/bin/env python3
"""Keep the AWS scan stage on the canonical script-pack command."""

import re
from pathlib import Path


MODULE = Path(__file__).resolve().parent.parent


def main() -> None:
    workflow = (MODULE / "workflows_discovery.tf").read_text()
    workflow_runbooks = workflow.split("runbook_refs =", 1)[1].split("\n", 1)[0]
    assert "null" in workflow_runbooks
    assert "local.sop_" not in workflow

    scan_stage = workflow.split('stage_id         = "cloud2code-scan-aws"', 1)[1]
    scan_stage = scan_stage.split('stage_id         = "cloud2code-scan-loop"', 1)[0]
    assert "do not call `create_agent`" in scan_stage
    assert "skill_refs = null" in scan_stage
    assert "${local.aws_migrator_spawn_context_cloud2code}" in scan_stage

    preflight_stage = workflow.split('stage_id  = "runner-capability-preflight"', 1)[1]
    preflight_stage = preflight_stage.split('stage_id         = "preflight-retry-loop"', 1)[0]
    assert "`working_dir` must be `/` or omitted" in preflight_stage
    assert '"preflight-retry-loop"' in workflow
    retry_loop = workflow.split('stage_id         = "preflight-retry-loop"', 1)[1]
    assert "missing_runner_evidence" not in retry_loop.split("exit_match", 1)[1].split("\n", 1)[0]

    context = (MODULE / "stage_context.tf").read_text()
    scan_context = context.split(
        "aws_migrator_spawn_context_cloud2code = <<-EOT", 1
    )[1].split("EOT", 1)[0]
    assert "Do not call create_agent" in scan_context
    assert "DIRECT_SCAN_COMMAND" in scan_context
    assert "${local.cloud2code_scan_execute_series_body}" in scan_context

    preflight_context = context.split("aws_migrator_spawn_context_preflight = <<-EOT", 1)[1].split("EOT", 1)[0]
    assert "Leave working_dir unset" in preflight_context

    main_tf = (MODULE / "main.tf").read_text()
    command = main_tf.split("cloud2code_scan_execute_series_body =", 1)[1].split(
        "\n", 1
    )[0]
    assert "cloud2code-aws-scan.sh" in command
    assert "cloud2code scan aws" not in command

    preload = re.search(
        r"^\s*script_pack_preload_dir\s*=\s*(.+)$", main_tf, re.MULTILINE
    ).group(1)
    assert "/opt/aws-migrator/script-pack/" in preload, preload
    assert "runner_work_home" not in preload, preload

    embed = (MODULE.parent.parent.parent / "runner" / "embed-script-pack.sh").read_text()
    assert 'RUNTIME_DEST="$DEST"' in embed


    print("OK: discovery scan uses the direct script-pack command")


if __name__ == "__main__":
    main()
