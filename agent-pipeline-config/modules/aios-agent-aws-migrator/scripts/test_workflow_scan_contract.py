#!/usr/bin/env python3
"""Keep AWS discovery prompts short, consistent, and on the pack command."""

from __future__ import annotations

import re
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent
MAX_BINDING_NOTE = 2200
MAX_PERSONA = 4000


def _binding(workflow: str, stage_id: str) -> str:
    bindings = workflow.split("stage_bindings = [", 1)[1]
    match = re.search(
        rf'stage_id\s*=\s*"{re.escape(stage_id)}"', bindings
    )
    if not match:
        raise AssertionError(f"missing stage binding {stage_id!r}")
    chunk = bindings[match.end() :]
    nxt = re.search(r"\n    \{\n\s*stage_id\s*=", chunk)
    return chunk[: nxt.start()] if nxt else chunk


def _string_assign(text: str, key: str) -> str:
    match = re.search(rf'^\s*{re.escape(key)}\s*=\s*"(.*)"\s*$', text, re.MULTILINE)
    if not match:
        raise AssertionError(f"missing string assign {key!r}")
    return match.group(1)


def _heredoc_body(text: str, assign: str) -> str:
    match = re.search(rf"{re.escape(assign)}\s*=\s*<<-EOT\n", text)
    if not match:
        raise AssertionError(f"missing heredoc assignment {assign!r}")
    return text[match.end() :].split("\nEOT", 1)[0]


def main() -> None:
    workflow = (MODULE / "workflows_discovery.tf").read_text()
    context = (MODULE / "stage_context.tf").read_text()
    main_tf = (MODULE / "main.tf").read_text()
    persona = (MODULE / "personas" / "aws-migrator-architect.md.tftpl").read_text()
    guard = (MODULE / "_persona_guard.tf").read_text()

    # Workflow must not bind SOPs as runbooks.
    assert "null" in workflow.split("runbook_refs =", 1)[1].split("\n", 1)[0]
    assert "local.sop_" not in workflow

    # Persona: identity + hard rules only. No stage table, no SOP load list,
    # no mandatory read_notes protocol, no plan-and-delegate default.
    assert len(persona) <= MAX_PERSONA, len(persona)
    assert "Stage Ownership" not in persona
    assert "Stage Entry Protocol" not in persona
    assert "sop_orchestration_name" not in persona
    assert "plan and delegate" not in persona.lower()
    assert "never execute" not in persona.lower()
    assert "current stage note is the execution plan" in persona
    assert "*.md.tftpl" in guard

    # Scan: paste-first, one body, no create_agent, skills null.
    scan = _binding(workflow, "cloud2code-scan-aws")
    assert "skill_refs       = null" in scan or "skill_refs = null" in scan
    assert "${local.aws_migrator_spawn_context_cloud2code}" in scan
    assert "create_agent" in scan.lower()
    assert "do not create_agent" in scan.lower() or "Do not create_agent" in scan
    assert "session " not in scan.lower()
    assert len(_heredoc_body(scan, "note")) <= MAX_BINDING_NOTE

    scan_ctx = _heredoc_body(context, "aws_migrator_spawn_context_cloud2code")
    assert scan_ctx.count("${local.cloud2code_scan_execute_series_body}") == 1
    assert "DIRECT_SCAN_COMMAND" not in scan_ctx
    assert "session " not in scan_ctx.lower()
    assert "---BEGIN CLOUD2CODE_SCAN_EXECUTE_SERIES---" in scan_ctx

    command = main_tf.split("cloud2code_scan_execute_series_body =", 1)[1].split("\n", 1)[0]
    assert "cloud2code-aws-scan.sh" in command
    assert "cloud2code scan aws" not in command

    preload = re.search(
        r"^\s*script_pack_preload_dir\s*=\s*(.+)$", main_tf, re.MULTILINE
    ).group(1)
    assert "/opt/aws-migrator/script-pack/" in preload
    assert "runner_work_home" not in preload

    embed = (MODULE.parent.parent.parent / "runner" / "embed-script-pack.sh").read_text()
    assert 'RUNTIME_DEST="$DEST"' in embed

    # Preflight: short contract, working_dir guidance stays in spawn context.
    preflight = _binding(workflow, "runner-capability-preflight")
    assert "${local.aws_migrator_spawn_context_preflight}" in preflight
    assert "session " not in preflight.lower()
    assert len(_heredoc_body(preflight, "note")) <= MAX_BINDING_NOTE
    preflight_ctx = _heredoc_body(context, "aws_migrator_spawn_context_preflight")
    assert preflight_ctx.count("${local.runner_capability_preflight_execute_series_body}") == 1
    assert "working_dir: omit or /" in preflight_ctx

    gate = _binding(workflow, "preflight-blocked-gate")
    gate_match = _string_assign(gate, "match")
    assert "stage_summary:runner-capability-preflight=blocked:" not in gate_match
    assert "blocked:remote_runner_script_pack_missing" in gate_match

    # Ingest: skills null, one bootstrap body, unquoted false on blocked gate.
    ingest = _binding(workflow, "ingest-and-split")
    assert "skill_refs       = null" in ingest or "skill_refs = null" in ingest
    assert "${local.dbsplit_spawn_context_ingest}" in ingest
    assert "session " not in ingest.lower() and "trace " not in ingest.lower()
    assert len(_heredoc_body(ingest, "note")) <= MAX_BINDING_NOTE
    ingest_ctx = _heredoc_body(context, "dbsplit_spawn_context_ingest")
    assert ingest_ctx.count("${local.ingest_bootstrap_execute_command}") == 1
    assert "---BEGIN INGEST_BOOTSTRAP_EXECUTE_COMMAND---" in ingest_ctx

    ingest_gate = _binding(workflow, "ingest-blocked-gate")
    ingest_match = _string_assign(ingest_gate, "match")
    assert "count_reconciliation_ok[^\\\\n]{0,40}false" in ingest_match
    assert "script_pack_verify_ok[^\\\\n]{0,40}false" in ingest_match

    # Registry: paste from note, no create_agent, body once.
    registry = _binding(workflow, "registry-and-import-codegen")
    assert "${local.dbsplit_spawn_context_registry}" in registry
    assert "Do not create_agent" in registry or "do not create_agent" in registry.lower()
    assert "session " not in registry.lower()
    assert len(_heredoc_body(registry, "note")) <= MAX_BINDING_NOTE
    registry_ctx = _heredoc_body(context, "dbsplit_spawn_context_registry")
    assert registry_ctx.count("${local.iac_pr_execute_series_body}") == 1

    # Converge wording matches validation exit, not zero-diff.
    converge_loop = _binding(workflow, "shell-converge-loop")
    assert "terraform_validation_ok" in converge_loop
    assert "zero-diff" not in converge_loop.lower()
    stages_converge = workflow.split('stage_id    = "shell-converge-loop"', 1)[1].split(
        "},", 1
    )[0]
    assert "terraform_validation_ok" in stages_converge
    assert "zero-diff" not in stages_converge.lower()

    print("OK: discovery prompts are short, consistent, and pack-backed")


if __name__ == "__main__":
    main()
