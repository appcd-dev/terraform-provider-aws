locals {
  # GitHub integration sidecars do not ship opa. Default: defer validation to target-repo GHA.
  opa_validation_deferred_to_ci = !var.require_local_opa_validation

  opa_local_validation_summary = var.require_local_opa_validation ? trimspace(<<-EOT
    Local OPA validation is **required** in the GitHub sidecar before handoff or PR.
  EOT
  ) : trimspace(<<-EOT
    Local OPA validation is **optional** in the GitHub sidecar (opa is usually absent). Write packs, commit, push, open PR — **rules-validate** GitHub Actions is the authoritative gate.
  EOT
  )

  opa_pack_worker_validation_step = var.require_local_opa_validation ? trimspace(<<-EOT
    6. MUST run: `opa test ${local.target_clone_dir}/<PACK_DIR>` — fix Rego until PASS. Do not note success if opa test fails.
  EOT
  ) : trimspace(<<-EOT
    6. If `command -v opa` succeeds: run `opa test ${local.target_clone_dir}/<PACK_DIR>` and set `opa_test_passed` true/false. If opa is **not** on PATH (expected in GitHub sidecar): set `opa_test_passed=skipped_local`, note why, and **continue** — do NOT fail the worker. CI validates on the PR.
  EOT
  )

  opa_codify_run_tests_before_handoff = var.require_local_opa_validation ? trimspace(<<-EOT
    - After merge: `bash ${local.target_clone_dir}/rules/run-tests.sh` must exit 0 before handoff.
  EOT
  ) : trimspace(<<-EOT
    - Do **not** fail the stage because `opa` or `run-tests.sh` is missing locally. After manifest merge + commit, hand off and push. CI runs `run-tests.sh` on the PR.
  EOT
  )

  opa_method_run_tests_before_handoff = var.require_local_opa_validation ? trimspace(<<-EOT
    Parent **must** run `bash ${local.target_clone_dir}/rules/run-tests.sh` after merging packs and fix any failing packs before handoff. Fail closed if scaffold missing.
  EOT
  ) : trimspace(<<-EOT
    When opa is absent in the GitHub sidecar, **skip** local `run-tests.sh`. Ensure scaffold files exist, merge manifest, commit, and hand off. CI runs `run-tests.sh` on the PR branch.
  EOT
  )

  opa_method_quality_bar_opa_test = var.require_local_opa_validation ? "- `opa test` passes for every pack with `policy.rego`." : "- Local `opa test` may be skipped in the sidecar (`opa_test_passed=skipped_local`); CI must pass for packs with `policy.rego`."

  opa_sop_bootstrap_before_handoff = var.require_local_opa_validation ? trimspace(<<-EOT
    **Before handoff:** parent runs `bash ${local.target_clone_dir}/rules/run-tests.sh`. If any pack fails, fix or re-spawn that pack worker. Do not hand off with red local tests.
  EOT
  ) : trimspace(<<-EOT
    **Before handoff:** skip local `run-tests.sh` when opa is absent in the sidecar. Merge manifest, commit, push, and write top-level handoff notes. CI validates on the PR.
  EOT
  )

  opa_sop_pr_preflight_run_tests = var.require_local_opa_validation ? trimspace(<<-EOT
    2. `bash ${local.target_clone_dir}/rules/run-tests.sh` exits 0. If not, fail closed with `blocked:codify_tests_failed` — do not open PR.
  EOT
  ) : trimspace(<<-EOT
    2. Skip local `run-tests.sh` preflight (opa not in GitHub sidecar). Open the PR, then run the CI wait+self-heal loop until `${var.github_check_name}` is green.
  EOT
  )

  opa_workflow_pack_validation_bullet = var.require_local_opa_validation ? "- Each pack with policy.rego MUST pass: opa test <pack_dir>. Wrong test syntax: count(data.policy.deny with input as x). Right: count(deny) == 0 with input as x." : "- Local opa test is optional in the GitHub sidecar. If opa missing: set opa_test_passed=skipped_local in codify_pack_* JSON and continue. CI is authoritative."

  opa_workflow_codify_run_tests_bullet = local.opa_codify_run_tests_before_handoff

  opa_workflow_pr_preflight_item = var.require_local_opa_validation ? "2) bash ${local.target_clone_dir}/rules/run-tests.sh must exit 0. If red → blocked:codify_tests_failed (do not open PR)." : "2) Skip local run-tests.sh. Open PR, then CI wait+self-heal loop until \"${var.github_check_name}\" green."

  codify_handoff_promotion_note = trimspace(<<-EOT
        MANDATORY top-level notes before rules-codify ends (subagent: keys are NOT visible to rules-pr):
        - note(codify_branch=<branch name>)
        - note(codify_bootstrap_done=true) when bootstrap ran
        - note(codify_rules_written=true) after commits on branch
        - note(codify_branch_pushed=true) after push succeeds
        - note(codify_handoff_json=<JSON with branch, commit_sha, repo_full, rules_written>)
  EOT
  )
}
