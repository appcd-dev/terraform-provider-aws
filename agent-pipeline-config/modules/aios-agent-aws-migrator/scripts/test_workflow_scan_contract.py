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


def _assert_gate_not_in_finish(gate_match: str, exit_match: str, label: str) -> None:
    """Gate match must not fire on a FINISH reason that only embeds exit_match."""
    finish = f'output matches regex "{exit_match}" — loop complete'
    gate_re = gate_match.encode("utf-8").decode("unicode_escape")
    assert not re.search(gate_re, finish), f"{label}: gate matched FINISH: {finish}"


def main() -> None:
    workflow = (MODULE / "workflows_discovery.tf").read_text()
    context = (MODULE / "stage_context.tf").read_text()
    main_tf = (MODULE / "main.tf").read_text()
    persona = (MODULE / "personas" / "aws-migrator-architect.md.tftpl").read_text()
    guard = (MODULE / "_persona_guard.tf").read_text()
    contract = (MODULE / "templates" / "discovery-stage-contract.md.tftpl").read_text()
    scan_sop = (MODULE / "templates" / "cloud2code-aws-region-scan.md.tftpl").read_text()

    # Explicit generic contract SOP bypasses smart-runbook discovery.
    assert "sg_runbook_sop.discovery_stage_contract.name" in workflow
    assert "discovery_stage_contract" in main_tf
    assert "runbook_refs = [sg_runbook_sop.discovery_stage_contract.name]" in workflow
    assert "local.sop_" not in workflow or "local.sop_discovery" in main_tf

    # Contract and scan SOP must stay Generic under Guild classifier signals:
    # <2 numbered steps, no must/shall/do-not-skip pairs with verify cues.
    assert not re.search(r"(?m)^\s*\d+[\.\)]\s+\S", contract)
    assert not re.search(r"(?m)^\s*\d+[\.\)]\s+\S", scan_sop)
    assert "## Procedure" not in scan_sop
    assert "stage note wins" in contract.lower() or "current stage note wins" in contract.lower()

    # Persona: identity + hard rules only; plain English, no sentinel catalogs.
    assert len(persona) <= MAX_PERSONA, len(persona)
    assert "Stage Ownership" not in persona
    assert "Stage Entry Protocol" not in persona
    assert "sop_orchestration_name" not in persona
    assert "plan and delegate" not in persona.lower()
    assert "never execute" not in persona.lower()
    assert "current stage note is the execution plan" in persona
    assert "Prescriptive Runbook Step" in persona
    assert "Prefer the pack command" in persona
    assert "blocked:remote_runner" not in persona
    assert "*.md.tftpl" in guard

    # Scan: pack-backed, create_agent allowed, skills empty.
    scan = _binding(workflow, "cloud2code-scan-aws")
    assert "skill_refs       = []" in scan or "skill_refs = []" in scan
    assert "discovery_stage_contract.name" in scan
    assert "${local.aws_migrator_spawn_context_cloud2code}" in scan
    assert "create_agent" in scan.lower()
    assert "do not create_agent" not in scan.lower()
    assert "prefer the pack command" in scan.lower()
    assert "cloud2code_scan_ok" in scan
    assert "echo the runner" in scan.lower() or "do not paraphrase" in scan.lower()
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
    assert "discovery_stage_contract.name" in preflight
    assert "${local.aws_migrator_spawn_context_preflight}" in preflight
    assert "prefer the pack command" in preflight.lower()
    assert "session " not in preflight.lower()
    assert len(_heredoc_body(preflight, "note")) <= MAX_BINDING_NOTE
    preflight_ctx = _heredoc_body(context, "aws_migrator_spawn_context_preflight")
    assert preflight_ctx.count("${local.runner_capability_preflight_execute_series_body}") == 1
    assert "working_dir: omit or /" in preflight_ctx

    gate = _binding(workflow, "preflight-blocked-gate")
    gate_match = _string_assign(gate, "match")
    assert "stage_summary:runner-capability-preflight=blocked:" not in gate_match
    assert "blocked:remote_runner_script_pack_missing:" in gate_match
    assert re.search(r"blocked:remote_runner_script_pack_missing:\\s*", gate_match)
    assert not re.search(
        r"blocked:remote_runner_script_pack_missing\|", gate_match
    ), "preflight gate must use emitted :true forms, not bare names"

    # Ingest: skills empty, one bootstrap body, concrete false on blocked gate.
    ingest = _binding(workflow, "ingest-and-split")
    assert "skill_refs       = []" in ingest or "skill_refs = []" in ingest
    assert "discovery_stage_contract.name" in ingest
    assert "${local.dbsplit_spawn_context_ingest}" in ingest
    assert "create_agent" in ingest.lower()
    assert "session " not in ingest.lower() and "trace " not in ingest.lower()
    assert len(_heredoc_body(ingest, "note")) <= MAX_BINDING_NOTE
    ingest_ctx = _heredoc_body(context, "dbsplit_spawn_context_ingest")
    assert ingest_ctx.count("${local.ingest_bootstrap_execute_command}") == 1
    assert "---BEGIN INGEST_BOOTSTRAP_EXECUTE_COMMAND---" in ingest_ctx

    ingest_gate = _binding(workflow, "ingest-blocked-gate")
    ingest_match = _string_assign(ingest_gate, "match")
    assert "script_pack_verify_ok=false" in ingest_match
    assert "count_reconciliation_ok=false" in ingest_match
    assert "script_pack_verify_ok[^\\\\n]{0,40}false" not in ingest_match
    assert "count_reconciliation_ok[^\\\\n]{0,40}false" not in ingest_match

    ingest_loop = _binding(workflow, "ingest-split-loop")
    ingest_exit = _string_assign(ingest_loop, "exit_match")
    _assert_gate_not_in_finish(ingest_match, ingest_exit, "ingest")
    gate_re = ingest_match.encode("utf-8").decode("unicode_escape")
    assert re.search(gate_re, "count_reconciliation_ok=false\n")
    assert re.search(gate_re, 'script_pack_verify_ok: "false"\n')
    assert not re.search(
        gate_re, "count_reconciliation_ok=true\nscript_pack_verify_ok=true\n"
    )

    # Scan gate vs scan loop FINISH embedding.
    scan_gate = _binding(workflow, "scan-blocked-gate")
    scan_match = _string_assign(scan_gate, "match")
    scan_loop = _binding(workflow, "cloud2code-scan-loop")
    scan_exit = _string_assign(scan_loop, "exit_match")
    _assert_gate_not_in_finish(scan_match, scan_exit, "scan")
    assert 'blocked:missing_aws_region:' in scan_match
    assert re.search(r"blocked:missing_aws_region:\\s*", scan_match)

    # Registry: pack-backed, create_agent allowed, body once.
    registry = _binding(workflow, "registry-and-import-codegen")
    assert "${local.dbsplit_spawn_context_registry}" in registry
    assert "create_agent" in registry.lower()
    assert "do not create_agent" not in registry.lower()
    assert "prefer the pack command" in registry.lower()
    assert "session " not in registry.lower()
    assert len(_heredoc_body(registry, "note")) <= MAX_BINDING_NOTE
    registry_ctx = _heredoc_body(context, "dbsplit_spawn_context_registry")
    assert registry_ctx.count("${local.iac_pr_execute_series_body}") == 1

    # Converge wording matches validation exit, not zero-diff; gate vs FINISH.
    converge = _binding(workflow, "shell-converge-matrix")
    assert "create_agent" in converge.lower()
    assert "prefer the pack command" in converge.lower()
    assert len(_heredoc_body(converge, "note")) <= MAX_BINDING_NOTE

    converge_loop = _binding(workflow, "shell-converge-loop")
    assert "terraform_validation_ok" in converge_loop
    assert "zero-diff" not in converge_loop.lower()
    assert "stage_summary:shell-converge-matrix=blocked:" not in _string_assign(
        converge_loop, "exit_match"
    )
    stages_converge = workflow.split('stage_id    = "shell-converge-loop"', 1)[1].split(
        "},", 1
    )[0]
    assert "terraform_validation_ok" in stages_converge
    assert "zero-diff" not in stages_converge.lower()

    converge_gate = _binding(workflow, "converge-blocked-gate")
    converge_match = _string_assign(converge_gate, "match")
    converge_exit = _string_assign(converge_loop, "exit_match")
    _assert_gate_not_in_finish(converge_match, converge_exit, "converge")
    assert "blocked:remote_runner_tofu_missing:" in converge_match
    assert re.search(r"blocked:remote_runner_tofu_missing:\\s*", converge_match)
    assert "stage_summary:shell-converge-matrix=blocked:" not in converge_match
    # FINISH embedding that previously false-skipped (session 03c3512c).
    false_skip = (
        'output matches regex "terraform_validation_ok[^\\n]{0,40}true|'
        "blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|"
        'stage_summary:shell-converge-matrix=blocked:" — loop complete'
    )
    converge_re = converge_match.encode("utf-8").decode("unicode_escape")
    assert not re.search(converge_re, false_skip), false_skip
    assert re.search(
        converge_re, 'blocked:remote_runner_tofu_missing: "true"\n'
    )

    print("OK: discovery prompts are short, consistent, and pack-backed")


if __name__ == "__main__":
    main()
