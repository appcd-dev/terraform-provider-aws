locals {
  ci_repair_loop_instructions = trimspace(<<-EOT
    ### CI wait + self-heal loop (mandatory — do not stop at first red check)

    After PR is open and `note(rules_pr_url=<url>)`, run up to ${var.ci_repair_max_iterations} repair cycles:

    **Cycle (repeat until green or max iterations):**

    1. Resolve PR number from `rules_pr_url` (or `gh pr list --repo ${local.default_target_repo_full} --head <codify_branch> --json number -q '.[0].number'`).
    2. ONE ${local.github_tool_prefix}_execute_series (timeout_seconds=${var.ci_gate_timeout_seconds}, working_dir=${local.target_clone_dir}) — copy verbatim, substitute CODIFY_PR_NUMBER:
    ${local.codify_ci_gate_execute_series_template}
    3. If stdout contains `codify_ci_status=green` → `note(codify_ci_green=true)`, `note(rules_codify_ok=true)`, stop.
    4. If failed: read failed logs from stdout. Classify and fix on branch (then push):
       - **Scaffold/workflow** (`conftest`, `no files found`, missing `run-tests.sh`, wrong workflow): ${local.codify_bootstrap_create_files_note} then git commit (verbatim):
         ${local.codify_scaffold_git_commit_execute_series_template}
       - **opa test** failure naming a pack dir: fix `policy.rego` / `policy_test.rego` / fixtures via create_files (absolute paths under ${local.target_clone_dir}).
       - **manifest** validation: fix `rules/manifest.json` schema/entries.
    5. Push repair commit — ONE execute_series (substitute CODIFY_BRANCH):
       ${local.codify_ci_push_execute_series_template}
    6. `note(codify_ci_iteration=<n>)` with failure summary; loop to step 1.

    FORBIDDEN: parsing `gh pr checks --json` (often empty). Use the CI gate script table output only.
    FORBIDDEN: shell heredocs (`cat <<`) for scaffold files — use create_files.
    After ${var.ci_repair_max_iterations} failed cycles → `blocked:codify_ci_failed` with last log excerpt. Do NOT merge.
  EOT
  )

  codify_bootstrap_create_files_note = trimspace(<<-EOT
    Write scaffold with **${local.github_tool_prefix}_create_files** (absolute paths under ${local.target_clone_dir}). Never invent YAML/shell via execute_series heredocs.
    Required paths: rules/README.md, rules/manifest.json (only if absent), rules/run-tests.sh, .github/workflows/rules-validate.yml.
    Use exact content from the BOOTSTRAP FILES block in this SOP. FORBIDDEN: conftest-action, instrumenta/conftest, or hand-written workflow differing from bootstrap.
  EOT
  )

  codify_bootstrap_scaffold_note = trimspace(<<-EOT
    ${local.codify_bootstrap_create_files_note}
    After create_files succeeds, commit with ONE execute_series (git only — no heredocs):
    ${local.codify_scaffold_git_commit_execute_series_template}
    Fallback only if create_files unavailable: ONE execute_series (python bootstrap — verbatim, no heredocs):
    ${local.codify_bootstrap_scaffold_execute_series_template}
  EOT
  )

  integration_shell_recovery_note = trimspace(<<-EOT
    ## Integration shell recovery (mandatory when tools fail)

    The GitHub sidecar blocks **environment enumeration** and shell-based file authoring patterns.

    **Never:** `env`, `printenv`, bare `export`, bare `set`, `cat <<EOF` / heredoc file writes, or inventing scaffold YAML in execute_series.

    **When execute_series returns `command blocked`:** do not fail the stage. Switch strategy:
    1. Scaffold/workflow files → **create_files** with absolute paths (primary).
    2. Git commit/push only → minimal execute_series with **git/gh only** (no file content in shell).
    3. Retry once with the approved python bootstrap script (verbatim) if create_files is insufficient.

    **When scaffold is missing at PR time:** create_files + git commit before declaring blocked. Only fail closed after create_files AND git commit both fail.
  EOT
  )
}
