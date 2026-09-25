#!/usr/bin/env python3
"""Contract: converge visits stay inside the 30m tool window and tfstate lands in the PR.

Trace 1c64c4a5 (wf-aws-cloud-discovery-ab79961875dd4c7b5): stages 1-4 succeeded
and opened PR #85, then shell-converge-matrix burned 10 visits on three failure
classes — (a) truncated workflow id running converge on an empty work root
until the 30m nile-runner timeout, (b) a full 83-group hydrate overrunning the
30m result-wait so retries overlapped and raced .git/index.lock, and (c) a
malformed ASG resource block init-failing 3x. The PR also never carried the
scanned tfstate because the repo .gitignore silently dropped *.tfstate.
"""

from __future__ import annotations

import re
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1]
SCRIPTS = MODULE / "scripts"
STAGE = (SCRIPTS / "stage-runner.sh").read_text(encoding="utf-8")
WORKFLOW = (MODULE / "workflows_discovery.tf").read_text(encoding="utf-8")
CONVERGE_TPL = (
    MODULE / "templates" / "converge-execute-series-embedded.sh.tftpl"
).read_text(encoding="utf-8")
REPO_GITIGNORE = (MODULE.parents[2] / ".gitignore").read_text(encoding="utf-8")


def test_converge_inputs_fail_fast() -> None:
    # Prepare artifacts must emit a terminal sentinel instead of jq-ing
    # missing files until the tool timeout.
    assert 'blocked:converge_inputs_missing: "true"' in STAGE
    assert "converge_input_error=missing_ingest_inputs" in STAGE
    assert "converge_input_error=bad_sample_group_ids" in STAGE
    assert "converge_input_error=missing_logical_group_manifest" in STAGE
    assert "converge_input_error=bad_manifest_group_count" in STAGE
    # The bootstrap template gates the same way before hydrate starts.
    assert 'blocked:converge_inputs_missing: "true"' in CONVERGE_TPL
    # No bare jq-on-missing-file numeric compares left in prepare artifacts.
    prepare = STAGE.split("cmd_prepare_parallel_artifacts() {", 1)[1].split("\n}\n", 1)[0]
    assert 'group_count="$(jq ' not in prepare or "|| echo 0" in prepare
    assert "[[ \"$group_count\" =~ ^[0-9]+$ ]]" in prepare


def test_converge_visit_budget_and_serialization() -> None:
    # Wall-clock budget default 1200s so a visit finishes inside the 30m
    # nile-runner result-wait window.
    assert "DBSPLIT_HYDRATE_VISIT_BUDGET_SECONDS" in STAGE
    assert ":-1200" in STAGE
    assert "reason=visit_time_budget budget_seconds=" in STAGE
    # Deferred groups still drive the loop GO_BACK via remaining>0.
    assert "hydrate_groups_remaining=" in STAGE
    # Visits are serialized so a retried tool call cannot overlap the prior one.
    assert 'acquire_run_lock "$work_root" "converge-visit"' in STAGE
    assert "hydrate_incomplete_reason=visit_lock_held" in STAGE
    # Every exit path releases the visit lock.
    matrix = STAGE.split("cmd_hydrate_and_plan_matrix() {", 1)[1]
    matrix = matrix.split("\ncmd_", 1)[0]
    releases = matrix.count('release_run_lock "$visit_lock"')
    assert releases >= 2, releases


def test_stale_git_index_lock_cleanup() -> None:
    assert "clear_stale_git_index_lock" in STAGE
    assert "git_index_lock_cleared=stale" in STAGE
    # Called before both sync paths that mutate the clone.
    sync = STAGE.split("cmd_sync_hydrated_iac_pr() {", 1)[1].split("\n}\n", 1)[0]
    assert "clear_stale_git_index_lock" in sync
    commit = STAGE.split("cmd_commit_pr() {", 1)[1].split("\n}\n", 1)[0]
    assert "clear_stale_git_index_lock" in commit


def test_tfstate_committed_to_pr() -> None:
    # The monolith + shards are the PR's core artifact: force-add beats ignore.
    assert "git add -A --force" in STAGE or "git add --force" in STAGE
    commit = STAGE.split("cmd_commit_pr() {", 1)[1].split("\n}\n", 1)[0]
    assert "aws/artifacts/cloud2code" in commit or "aws/artifacts/cloud2code" in STAGE
    assert "find aws/artifacts/cloud2code -type f -name '*.tfstate'" in commit
    assert "tfstate_committed=true" in commit
    assert "monolith_tfstate_tracked=" in commit
    assert "tfstate_tracked_count=" in commit
    # Repo allowlist so a plain git add also works (belt and suspenders).
    assert "!aws/artifacts/cloud2code/**" in REPO_GITIGNORE
    assert "!aws/groups/**/*.tfstate" in REPO_GITIGNORE


def test_drop_list_or_block_attr_balanced_scan() -> None:
    # The fix must scan a balanced, string-aware span and support '{' openers;
    # the old single-line fallback orphaned the value body (trace 1c64c4a5:
    # bare '{' on generated.tf line 6 → init_failed x3).
    py = STAGE.split("def drop_list_or_block_attr", 1)[1]
    assert "in_str" in py
    assert 'elif ch == ("]" if opener == "[" else "}")' in py


def test_workflow_wiring() -> None:
    # Loop exits on the new terminal sentinel; the blocked gate skips onward.
    converge_loop = WORKFLOW.split('stage_id         = "shell-converge-loop"', 1)[1]
    m = re.search(r'exit_match = "((?:[^"\\]|\\.)*)"', converge_loop)
    exit_match = m.group(1)
    assert "blocked:converge_inputs_missing" in exit_match
    gates = re.findall(r'match   = "((?:[^"\\]|\\.)*)"', WORKFLOW)
    assert any("blocked:converge_inputs_missing" in g for g in gates), gates
    # Stage note teaches the agent not to retry converge on a wrong run id.
    converge = WORKFLOW.split("stage_id         = \"shell-converge-matrix\"", 1)[1]
    assert "blocked:converge_inputs_missing" in converge


def main() -> None:
    test_converge_inputs_fail_fast()
    test_converge_visit_budget_and_serialization()
    test_stale_git_index_lock_cleanup()
    test_tfstate_committed_to_pr()
    test_drop_list_or_block_attr_balanced_scan()
    test_workflow_wiring()
    print("OK: converge resilience + tfstate-in-PR contract")


if __name__ == "__main__":
    main()