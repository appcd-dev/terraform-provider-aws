#!/usr/bin/env python3
"""Destination PR must open with OPA TODOs; governance loop remediates first."""

from __future__ import annotations

import re
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent
STAGE = MODULE / "scripts" / "stage-runner.sh"
GCP_WF = MODULE / "workflows_gcp_only.tf"
AZURE_WF = MODULE / "workflows_azure_only.tf"
SOP = MODULE / "templates" / "nile-governance-learn-and-conform.md.tftpl"


def main() -> None:
    stage = STAGE.read_text()
    # Soft gate: no hard pr_blocker return for governance.
    soft = re.search(
        r"require_destination_governance_ok\(\) \{.*?^}",
        stage,
        re.MULTILINE | re.DOTALL,
    )
    assert soft, "missing require_destination_governance_ok"
    body = soft.group(0)
    assert "return 0" in body
    assert "governance_residual" in body
    assert "opening_pr_with_todos" in body
    assert "pr_blocker" not in body
    assert "blocked:governance_nonconformant" not in body

    assert "emit_governance_residual_md()" in stage
    assert "governance-opa-fix-hints.md" in stage
    assert "TODO — clear residuals" in stage
    assert "governance-opa-guidance.json" in stage
    assert "trace source evidence" in stage
    assert "apply_opa_mechanical_fixes" not in stage
    assert "apply_opa_mechanical_fixes" not in (MODULE / "scripts" / "run-destination-stage.sh").read_text()
    assert "governance-opa-no-progress.json" in stage
    assert "same_opa_findings_across_agent_visits" in stage
    assert "local opa_guidance=" in stage
    assert "Rego-authored guidance" in stage
    assert "governance-evidence-check.json" in stage
    assert "governance_evidence_incomplete" in stage
    assert "source_sha" in stage and "inventory_resources" in stage
    assert 'stage_summary:${stage_id}" "nonconformant:governance_residual"' in stage

    for wf_path, cloud in ((GCP_WF, "gcp"), (AZURE_WF, "azure")):
        wf = wf_path.read_text()
        # Loop must keep remediating while ok=false.
        m = re.search(
            rf'exit_match\s*=\s*"(.*{cloud}_iac_governance_ok.*)"\s*$',
            wf,
            re.MULTILINE,
        )
        assert m, f"missing governance exit_match in {wf_path.name}"
        exit_match = m.group(1)
        assert f"{cloud}_iac_governance_ok" in exit_match
        assert "true" in exit_match
        assert "false" not in exit_match
        assert f"stage_summary:{cloud}-iac-governance-conform=ok|" not in exit_match
        assert "opens with TODOs" in wf or "documents" in wf
        assert "blocked:governance_evidence_incomplete" in wf
        if cloud == "gcp":
            assert "failure_classes" in wf
            assert "governance_nonconformant" in wf
            assert "do not imply apply readiness" in wf

    sop = SOP.read_text()
    assert "still opens with TODO" in sop or "document them in TODO" in sop
    assert "assumptions" in sop.lower()
    assert "without a PR" in sop or "no destination PR" in sop
    assert "governance-opa-guidance.json" in sop

    print("OK: governance soft-gate + remediation-loop contracts")


if __name__ == "__main__":
    main()
