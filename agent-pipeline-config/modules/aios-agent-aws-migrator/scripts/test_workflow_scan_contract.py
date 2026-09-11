#!/usr/bin/env python3
"""Keep the AWS scan stage on the canonical script-pack command."""

from pathlib import Path


MODULE = Path(__file__).resolve().parent.parent


def main() -> None:
    workflow = (MODULE / "workflows_discovery.tf").read_text()
    scan_stage = workflow.split('stage_id         = "cloud2code-scan-aws"', 1)[1]
    scan_stage = scan_stage.split('stage_id         = "cloud2code-scan-loop"', 1)[0]
    assert "do not call `create_agent`" in scan_stage
    assert "skill_refs = null" in scan_stage
    assert "${local.aws_migrator_spawn_context_cloud2code}" in scan_stage

    context = (MODULE / "stage_context.tf").read_text()
    scan_context = context.split(
        "aws_migrator_spawn_context_cloud2code = <<-EOT", 1
    )[1].split("EOT", 1)[0]
    assert "Do not call create_agent" in scan_context
    assert "DIRECT_SCAN_COMMAND" in scan_context
    assert "${local.cloud2code_scan_execute_series_body}" in scan_context

    main_tf = (MODULE / "main.tf").read_text()
    command = main_tf.split("cloud2code_scan_execute_series_body =", 1)[1].split(
        "\n", 1
    )[0]
    assert "cloud2code-aws-scan.sh" in command
    assert "cloud2code scan aws" not in command

    print("OK: discovery scan uses the direct script-pack command")


if __name__ == "__main__":
    main()
