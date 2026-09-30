#!/usr/bin/env python3
"""Contract for reasoning-skill registration and stage scope."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_workflow_scan_contract as contract

MODULE = Path(__file__).resolve().parent.parent


def _stage(source: str, stage_id: str) -> str:
    candidates = (
        f'stage_id         = "{stage_id}"',
        f'stage_id      = "{stage_id}"',
        f'stage_id    = "{stage_id}"',
    )
    start = next((source.index(marker) for marker in candidates if marker in source), None)
    if start is None:
        raise AssertionError(f"missing stage {stage_id}")
    end = source.find("\n    {", start + 1)
    return source[start:] if end < 0 else source[start:end]


def main() -> None:
    main_tf = (MODULE / "main.tf").read_text(encoding="utf-8")
    discovery = (MODULE / "workflows_discovery.tf").read_text(encoding="utf-8")
    assert 'planner_max_tool_iterations = 20' in (MODULE / "workflows_azure_only.tf").read_text(encoding="utf-8")
    azure = (MODULE / "workflows_azure_only.tf").read_text(encoding="utf-8")
    gcp = (MODULE / "workflows_gcp_only.tf").read_text(encoding="utf-8")
    gcp_workflow = gcp
    template_dir = MODULE / "templates"

    skill_resources = {
        "aws_discovery_pr_review": "aws-discovery-pr-review.md",
        "terraform_diagnose_edit_verify": "terraform-diagnose-edit-verify.md",
        "rego_plan_reasoning": "rego-plan-reasoning.md",
        "mapping_provider_schema_reasoning": "mapping-catalog-provider-schema.md",
        "mapping_catalog_knowledge": "discovery-mapping-review-reference.md",
        "destination_iac_wiring_readiness": "destination-iac-wiring-readiness.md",
    }
    for resource_name, template_name in skill_resources.items():
        assert main_tf.count(f'resource "sg_runbook_sop" "{resource_name}"') == 1
        assert f'rendered_templates["{template_name}"]' in main_tf
        assert (template_dir / f"{template_name.replace('.md', '.tmpl.md')}").is_file()

    # PR review is attached only at PR creation/final operator handoff.
    for source, stage_id in ((discovery, "registry-and-import-codegen"), (discovery, "final-gate-and-memory"), (azure, "azure-pr"), (azure, "azure-only-final"), (gcp, "gcp-pr"), (gcp, "gcp-only-final")):
        assert "sg_runbook_sop.aws_discovery_pr_review.name" in _stage(source, stage_id)
    for source, stage_id in ((discovery, "cloud2code-scan-aws"), (discovery, "ingest-and-split"), (azure, "azure-source-fetch"), (gcp, "gcp-source-fetch")):
        assert "aws_discovery_pr_review" not in _stage(source, stage_id)

    # Terraform failure reasoning is only attached where diagnostics are edited.
    for source, stage_id in ((discovery, "shell-converge-matrix"), (azure, "azure-iac-validate"), (azure, "azure-iac-harden"), (gcp, "gcp-iac-harden")):
        assert "sg_runbook_sop.terraform_diagnose_edit_verify.name" in _stage(source, stage_id)
    # GCP validator's stage_id uses a different alignment than the common form.
    assert "sg_runbook_sop.terraform_diagnose_edit_verify.name" in gcp_workflow.split('stage_id      = "gcp-iac-validate"', 1)[1].split("\n    {", 1)[0]

    # Mapping/schema guidance is attached at decisions and generated HCL.
    for source, stage_id in ((azure, "azure-migration-blueprint"), (azure, "azure-iac-generate"), (gcp, "gcp-migration-blueprint"), (gcp, "gcp-iac-generate"), (discovery, "registry-and-import-codegen")):
        block = _stage(source, stage_id)
        assert "sg_runbook_sop.mapping_provider_schema_reasoning.name" in block
        assert "sg_runbook_sop.mapping_catalog_knowledge.name" in block

    # Rego reasoning is scoped to the policy evaluator stages.
    for source, stage_id in ((azure, "azure-iac-governance-conform"), (gcp, "gcp-iac-governance-conform")):
        assert "sg_runbook_sop.rego_plan_reasoning.name" in _stage(source, stage_id)
    assert "rego_plan_reasoning" not in _stage(discovery, "cloud2code-scan-aws")

    review = (template_dir / "aws-discovery-pr-review.tmpl.md").read_text(encoding="utf-8")
    assert "not a template for conclusions" in review
    mapping = (template_dir / "mapping-catalog-provider-schema.tmpl.md").read_text(encoding="utf-8")
    assert "Terraform Registry" in mapping
    assert "pinned-version" in mapping
    assert "is not an exhaustive answer" in mapping
    assert "mapping-research.md" in mapping
    assert "low-confidence AWS→GCP mappings using source evidence and Terraform Registry/provider docs" in gcp
    assert "Terraform Registry" in gcp
    assert "Terraform Registry" in azure and "azure/artifacts/mapping-research.md" in azure
    assert "Terraform Registry provider/resource documentation" in gcp
    assert "use `web_search`" in gcp
    assert "search Terraform Registry for AzureRM resource/data-source candidates and reusable modules" in azure
    assert "pinned AzureRM docs" in azure or "provider version pinned in each generated root" in azure
    assert "azure/artifacts/mapping-research.md" in azure
    assert "hard evidence gate" in azure.lower()
    assert "mapping_research_missing" in azure
    assert "azure/artifacts/mapping-research.md" in azure
    assert "create_files" in azure
    assert "`web_search`" in azure
    assert "hard evidence gate" in gcp.lower()
    assert "mapping_research_missing" in gcp
    assert "gcp/artifacts/mapping-research.md" in gcp
    assert "create_files" in gcp
    assert "`web_search`" in gcp
    assert '"web_search"' in main_tf
    runner = (MODULE / "scripts/stage-runner.sh").read_text()
    assert "azure/artifacts/mapping-research.md || rc=$?" in runner
    assert "gcp/artifacts/mapping-research.md || rc=$?" in runner
    assert "azure/artifacts/mapping-research.md" in runner
    assert "gcp/artifacts/mapping-research.md" in runner
    assert "Do not stop on the first `source_coverage_below_90_percent`" in azure
    assert "Continue until ≥90% or evidence proves that threshold cannot be safely met" in gcp
    assert "bounded repair loop" in gcp
    assert "search the **Terraform Registry**" in mapping
    assert "search/modules?q=" in mapping
    assert "hashicorp/azurerm/<pinned-version>" in mapping
    assert "completeness verdict" in review
    terraform = (template_dir / "terraform-diagnose-edit-verify.tmpl.md").read_text(encoding="utf-8")
    assert "successful write is not proof" in terraform
    rego = (template_dir / "rego-plan-reasoning.tmpl.md").read_text(encoding="utf-8")
    assert "exact plan JSON path/value" in rego
    mapping = (template_dir / "mapping-catalog-provider-schema.tmpl.md").read_text(encoding="utf-8")
    assert "not another mapping table" in mapping
    knowledge = (template_dir / "discovery-mapping-review-reference.tmpl.md").read_text(encoding="utf-8")
    assert "do not copy or create a second static mapping table" in knowledge.lower()

    print("OK: discovery reasoning skills registered with stage-scoped attachments")


if __name__ == "__main__":
    main()
