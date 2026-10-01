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
    assert "never memory" in persona or "from memory" in persona
    assert "targeted read-only probe" in persona
    assert "sync the discovery PR" in persona
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
    assert "timeout_seconds" in scan
    assert "signal: killed" in scan
    assert "cloud2code_scan_running" in scan
    assert "echo the runner" in scan.lower() or "do not paraphrase" in scan.lower()
    assert "session " not in scan.lower()
    assert len(_heredoc_body(scan, "note")) <= MAX_BINDING_NOTE

    scan_ctx = _heredoc_body(context, "aws_migrator_spawn_context_cloud2code")
    assert scan_ctx.count("${local.cloud2code_scan_execute_series_body}") == 1
    assert "DIRECT_SCAN_COMMAND" not in scan_ctx
    assert "session " not in scan_ctx.lower()
    assert "---BEGIN CLOUD2CODE_SCAN_EXECUTE_SERIES---" in scan_ctx

    command = re.search(
        r"cloud2code_scan_execute_series_body\s*=\s*\"(.*)\"\s*$",
        main_tf,
        re.MULTILINE,
    ).group(1)
    invoke = re.search(
        r"runner_pack_entry_invoke\s*=\s*\"(.*)\"\s*$",
        main_tf,
        re.MULTILINE,
    ).group(1)
    entry_url = re.search(
        r"script_pack_entry_url\s*=\s*\"(.*)\"\s*$",
        main_tf,
        re.MULTILINE,
    ).group(1)
    assert "pack-entry.sh" in entry_url
    assert "gh release download" in invoke
    assert "pack-entry.sh" in invoke
    assert "runner_pack_entry_invoke" in main_tf
    assert "case \"$${1}\" in" not in invoke
    pack_entry = (MODULE / "scripts" / "pack-entry.sh").read_text()
    assert 'converge)' in pack_entry
    assert 'export WORKFLOW_RUN_ID="${1:-${WORKFLOW_RUN_ID:-}}"' in pack_entry
    assert "cloud2code-scan-detach.sh" in pack_entry
    assert 'export CLOUD2CODE_EXCLUDE="${_scan_exclude}"' in pack_entry
    detach = (MODULE / "scripts" / "cloud2code-scan-detach.sh").read_text()
    assert "setsid" in detach
    assert 'cloud2code_scan_running: "true"' in detach
    assert "cloud2code-scan-detach.sh" in (MODULE / ".." / ".." / ".." / "runner" / "embed-script-pack.sh").read_text()
    assert "workflow-run-id.sh" in (MODULE / "scripts" / "cloud2code-scan-detach.sh").read_text()
    assert "wf-[a-z0-9]" in (MODULE / "scripts" / "workflow-run-id.sh").read_text()
    assert "runner_pack_entry_invoke" in command
    assert " scan " in command
    assert "CLOUD2CODE_EXCLUDE_PLACEHOLDER" in command
    assert "cloud2code scan aws" not in command
    preflight_cmd = re.search(
        r"runner_capability_preflight_execute_series_body\s*=\s*\"(.*)\"\s*$",
        main_tf,
        re.MULTILINE,
    ).group(1)
    assert "runner_pack_entry_invoke" in preflight_cmd
    assert "preflight" in preflight_cmd
    # /opt-prefer pack_entry + AWS cred hygiene glue is intentionally longer than
    # the old gh-only one-liner; cap runaway growth, not the old 550 ceiling.
    assert len(invoke) < 1600, f"pack-entry invoke too long: {len(invoke)}"
    assert len(command) < 200, f"scan body too long: {len(command)}"
    assert len(preflight_cmd) < 200, f"preflight body too long: {len(preflight_cmd)}"

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

    # Ingest: fail closed unless the scan wrapper persisted its completed marker.
    ingest_template = (MODULE / "templates" / "ingest-execute-series-embedded.sh.tftpl").read_text()
    assert '.cloud2code_scan_ok == "true"' in ingest_template
    assert "blocked:cloud2code_scan_incomplete" in ingest_template
    assert "non-throttling" in scan
    assert "partial inventories" in scan
    assert "Continue ingest/split" in scan
    assert "failure counters" in scan
    assert "cloud2code_allow_partial=false" in scan
    assert "No minimum coverage floor" in scan
    assert "read_failed" in scan
    assert "throttling" in scan

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
    # Quoted true only (session c38ad01b prose false-FINISH).
    assert r'count_reconciliation_ok:\\s*\\\"true\\\"' in ingest_exit
    assert "count_reconciliation_ok[^\\\\n]{0,40}true" not in ingest_exit
    assert "blocked:split_lock_timeout" in ingest_exit
    assert r'blocked:cloud2code_scan_incomplete:\\s*\\\"true\\\"' in ingest_exit
    assert "blocked:cloud2code_scan_incomplete" in ingest_match
    gate_re = ingest_match.encode("utf-8").decode("unicode_escape")
    assert re.search(gate_re, "count_reconciliation_ok=false\n")
    assert re.search(gate_re, 'script_pack_verify_ok: "false"\n')
    assert re.search(gate_re, 'blocked:split_lock_timeout: "true"\n')
    assert not re.search(
        gate_re, "count_reconciliation_ok=true\nscript_pack_verify_ok=true\n"
    )
    # Prose that previously false-FINISHed must not match quoted exit_match.
    prose = (
        "The required `count_reconciliation_ok=true`, group paths, and "
        "`script_pack_verify_ok=true` lines were not produced."
    )
    exit_re = ingest_exit.encode("utf-8").decode("unicode_escape")
    assert not re.search(exit_re, prose), prose
    assert re.search(exit_re, 'count_reconciliation_ok: "true"\n')

    # Scan gate vs scan loop FINISH embedding.
    scan_gate = _binding(workflow, "scan-blocked-gate")
    scan_match = _string_assign(scan_gate, "match")
    scan_loop = _binding(workflow, "cloud2code-scan-loop")
    scan_exit = _string_assign(scan_loop, "exit_match")
    _assert_gate_not_in_finish(scan_match, scan_exit, "scan")
    assert 'blocked:missing_aws_region:' in scan_match
    assert re.search(r"blocked:missing_aws_region:\\s*", scan_match)
    # Session 3b08e860: a live import and a fingerprint mismatch must GO_BACK.
    # Bare blocker names in the stage note must not FINISH the loop.
    scan_exit_re = scan_exit.encode("utf-8").decode("unicode_escape")
    assert not re.search(scan_exit_re, 'cloud2code_scan_running: "true"\n')
    assert not re.search(
        scan_exit_re, 'blocked:cloud2code_scan_already_running: "true"\n'
    )
    assert not re.search(scan_exit_re, "blocked:cloud2code_scan_failed")
    assert re.search(scan_exit_re, 'blocked:cloud2code_scan_failed: "true"\n')

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
    assert "hcl_fix_target" in converge.lower()
    assert "hcl_fix_target_count>0" in converge or "hcl_fix_target_count" in converge
    assert "bare pack re-run" in converge.lower() or "no edits" in converge.lower()
    assert "blank" in converge.lower() or "truncate" in converge.lower()
    assert "converge_batch_incomplete" in converge or "converge_retryable" in converge
    assert "signal: killed" in converge or "runner_killed" in converge
    assert "never memory" in converge
    assert "one safe idempotent retry" in converge
    assert "even if an earlier retry was used" in converge
    assert "Keep the discovery PR synced" in converge
    assert len(_heredoc_body(converge, "note")) <= MAX_BINDING_NOTE

    converge_loop = _binding(workflow, "shell-converge-loop")
    assert "terraform_validation_ok" in converge_loop
    assert "zero-diff" not in converge_loop.lower()
    converge_exit = _string_assign(converge_loop, "exit_match")
    assert "stage_summary:shell-converge-matrix=blocked:" not in converge_exit
    # Conclusive false must FINISH (session e210eccd visit-cap abort).
    # Raw TF source keeps Terraform escapes (\\s, \\\").
    assert r'terraform_validation_ok:\\s*\\\"false\\\"' in converge_exit
    assert r'terraform_validation_ok:\\s*\\\"true\\\"' in converge_exit
    # Batch incomplete / kill resume must NOT FINISH the loop (omit validation_ok).
    assert "converge_batch_incomplete" not in converge_exit
    assert "converge_retryable" not in converge_exit
    assert "blocked:runner_killed" not in converge_exit
    stages_converge = workflow.split('stage_id    = "shell-converge-loop"', 1)[1].split(
        "},", 1
    )[0]
    assert "terraform_validation_ok" in stages_converge
    assert "zero-diff" not in stages_converge.lower()

    # Incomplete batch stdout must GO_BACK (no terraform_validation_ok line).
    exit_re = converge_exit.encode("utf-8").decode("unicode_escape")
    batch_out = (
        'converge_retryable: "true"\n'
        'converge_batch_incomplete: "true"\n'
        "hydrate_groups_remaining=12\n"
    )
    assert not re.search(exit_re, batch_out), batch_out
    assert re.search(exit_re, 'terraform_validation_ok: "false"\n')
    assert re.search(exit_re, 'terraform_validation_ok: "true"\n')
    converge_gate = _binding(workflow, "converge-blocked-gate")
    converge_match = _string_assign(converge_gate, "match")
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
    # Quoted false FINISH must not trip the blocked gate.
    false_finish = (
        'output matches regex "terraform_validation_ok:\\s*\\"false\\"" — loop complete'
    )
    assert not re.search(converge_re, false_finish), false_finish

    print("OK: discovery prompts are short, consistent, and pack-backed")


if __name__ == "__main__":
    main()
