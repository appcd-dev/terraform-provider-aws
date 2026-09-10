locals {
  codify_handoff_recovery_note = trimspace(<<-EOT
    ## Handoff recovery (mandatory when notes are empty)

    `workflow_notes_snapshot` may arrive with `"notes":{}`. Subagent-scoped keys (`subagent:*`, nested prefixes) are **not** visible to `rules-pr`. Do **not** fail immediately.

    **Recovery ladder (run in order, stop when `codify_branch` is known):**

    1. `read_notes` — use top-level `codify_branch`, `codify_handoff_json`, or `codify_inventory_json.source_commit_sha`.
    2. If still missing: ONE ${local.github_tool_prefix}_execute_series (git-only branch discovery — verbatim, substitute SOURCE_COMMIT_SHA from inventory when known):
       ${local.codify_branch_recover_execute_series_template}
    3. Parse stdout `codify_branch=...`. Immediately `note(codify_branch=<value>)` at **top level** (required for downstream tools).
    4. If recover script prints `codify_branch_recover=failed`: fail closed with `blocked:codify_pr_failed` only after step 2.

    **Then** checkout branch (verbatim, substitute CODIFY_BRANCH):
    ${local.codify_checkout_branch_execute_series_template}

    FORBIDDEN: declaring `blocked:codify_pr_failed` because `workflow_notes_snapshot.notes` is empty without running branch recovery first.
  EOT
  )

  codify_handoff_verify_note = trimspace(<<-EOT
    Before `rules-codify` ends — verify branch exists on origin (substitute CODIFY_BRANCH):
    ${local.codify_handoff_verify_execute_series_template}
    Must print `codify_branch_on_origin=1` and `codify_branch_ahead` > 0. If verify fails: push branch, then write top-level notes:
    note(codify_branch=...), note(codify_branch_pushed=true), note(codify_handoff_json=...).
  EOT
  )
}
