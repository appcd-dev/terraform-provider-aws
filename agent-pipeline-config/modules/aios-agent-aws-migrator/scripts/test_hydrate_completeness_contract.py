#!/usr/bin/env python3
"""Contract: hydrate emit-primary, stub tfvars, unlimited default visit, no Ready soft-exit."""

from __future__ import annotations

from pathlib import Path

MODULE = Path(__file__).resolve().parents[1]
RUNNER = (MODULE / "scripts" / "stage-runner.sh").read_text(encoding="utf-8")
WORKFLOW = (MODULE / "workflows_discovery.tf").read_text(encoding="utf-8")
CONVERGE_TPL = (
    MODULE / "templates" / "converge-execute-series-embedded.sh.tftpl"
).read_text(encoding="utf-8")
SHARD_DOC = (
    MODULE / "templates" / "terraform-state-shard-extraction.md.tftpl"
).read_text(encoding="utf-8")
DECOMPOSER = (
    MODULE / "scripts" / "tfstate_monolith_decomposer.py"
).read_text(encoding="utf-8")


def test_hydrate_emit_primary_and_stub_tfvars() -> None:
    assert "emit-from-state --replace" in RUNNER
    assert "write-stub-tfvars" in RUNNER
    assert "group_compile_ok=" in RUNNER
    assert "compile_ok" in RUNNER
    assert 'DBSPLIT_HYDRATE_MAX_GROUPS_PER_VISIT:-0' in RUNNER
    # Live generate is secondary after emit.
    emit_idx = RUNNER.index("emit-from-state --replace")
    gen_idx = RUNNER.index("plan -generate-config-out=generated.tf", emit_idx)
    assert emit_idx < gen_idx


def test_ready_requires_hydrate_complete() -> None:
    assert "hydrate_groups_remaining=0" in WORKFLOW
    assert "never label Result Ready" in WORKFLOW
    assert "compile_ok" in WORKFLOW


def test_converge_tpl_default_unlimited() -> None:
    assert "Default visit cap is unlimited" in CONVERGE_TPL
    assert "default 8" not in CONVERGE_TPL


def test_no_remote_state_scaffold_docs() -> None:
    assert "upstream_refs.json" in SHARD_DOC
    assert "literal" in SHARD_DOC.lower()
    assert "do **not** emit `terraform_remote_state`" in SHARD_DOC or (
        "do **not** emit" in SHARD_DOC and "terraform_remote_state" in SHARD_DOC
    )
    assert "scaffold_remote_state" in DECOMPOSER
    assert "No-op: do not emit terraform_remote_state" in DECOMPOSER
    assert 'os.remove(stale_upstream)' in DECOMPOSER or "stale_upstream" in DECOMPOSER


def main() -> None:
    test_hydrate_emit_primary_and_stub_tfvars()
    test_ready_requires_hydrate_complete()
    test_converge_tpl_default_unlimited()
    test_no_remote_state_scaffold_docs()
    print("OK: hydrate completeness + stub-plan contract")


if __name__ == "__main__":
    main()
