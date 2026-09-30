#!/usr/bin/env python3
"""Contract: destination wiring/apply-readiness guidance is registered and used."""
from __future__ import annotations

import re
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent


def stage(source: str, stage_id: str) -> str:
    match = re.search(rf'stage_id\s*=\s*"{re.escape(stage_id)}"', source)
    assert match, f"missing stage {stage_id}"
    tail = source[match.start():]
    end = re.search(r"\n    \{\n\s*stage_id\s*=", tail[1:])
    return tail[: end.start() + 1] if end else tail


def main() -> None:
    main_tf = (MODULE / "main.tf").read_text()
    workflow = (MODULE / "workflows_gcp_only.tf").read_text()
    skill = (MODULE / "templates/destination-iac-wiring-readiness.tmpl.md").read_text()
    assert main_tf.count('resource "sg_runbook_sop" "destination_iac_wiring_readiness"') == 1
    assert 'rendered_templates["destination-iac-wiring-readiness.md"]' in main_tf
    for stage_id in (
        "gcp-migration-blueprint",
        "gcp-iac-generate",
        "gcp-iac-validate",
        "gcp-iac-harden",
        "gcp-iac-governance-conform",
        "gcp-pr",
    ):
        assert "sg_runbook_sop.destination_iac_wiring_readiness.name" in stage(workflow, stage_id), stage_id
    assert "For each inventoried managed source instance" in skill
    assert "one-to-many or many-to-one" in skill
    assert "retention policy" in skill.lower()
    assert "Do not run `tofu apply`" in skill
    runner = (MODULE / "scripts/stage-runner.sh").read_text()
    assert "CloudWatch log groups → GCP log buckets" in runner
    assert "routing status" in runner
    print("OK: destination wiring skill registered and stage-scoped")


if __name__ == "__main__":
    main()
