locals {
  default_source_repo_full = replace(replace(replace(trimspace(var.default_source_repository_url), "https://github.com/", ""), "http://github.com/", ""), ".git", "")
  default_target_repo_full = replace(replace(replace(trimspace(var.default_target_repository_url), "https://github.com/", ""), "http://github.com/", ""), ".git", "")

  source_clone_dir = "/tmp/governance-source"
  target_clone_dir = "/tmp/governance-codify"

  codify_pr_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-pr-execute-series.sh.tftpl", {
    OWNER         = split("/", local.default_target_repo_full)[0]
    REPO          = split("/", local.default_target_repo_full)[1]
    BRANCH        = "SOURCE_COMMIT_SHA_YYYYMMDDHHMMSS"
    BASE_BRANCH   = trimspace(var.default_base_branch)
    CLONE_DIR     = local.target_clone_dir
    PR_TITLE      = "codify: governance OPA rules from ${local.default_source_repo_full}"
    PR_BODY_LINE1 = "Automated Rego + conftest rule packs from governance markdown."
    PR_BODY_LINE2 = "Source: ${local.default_source_repo_full}@${trimspace(var.default_source_ref)}. Branch: SOURCE_COMMIT_SHA_YYYYMMDDHHMMSS. See rules/manifest.json."
  }))

  codify_branch_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-branch-execute-series.sh.tftpl", {
    CLONE_DIR    = local.target_clone_dir
    BASE_BRANCH  = trimspace(var.default_base_branch)
  }))

  codify_push_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-push-execute-series.sh.tftpl", {
    CLONE_DIR = local.target_clone_dir
    BRANCH    = "CODIFY_BRANCH"
  }))

  codify_checkout_branch_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-checkout-branch-execute-series.sh.tftpl", {
    TARGET_DIR  = local.target_clone_dir
    TARGET_REPO = local.default_target_repo_full
  }))

  codify_intake_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-intake-execute-series.sh.tftpl", {
    SOURCE_DIR   = local.source_clone_dir
    TARGET_DIR   = local.target_clone_dir
    SOURCE_REPO  = local.default_source_repo_full
    TARGET_REPO  = local.default_target_repo_full
    SOURCE_REF   = trimspace(var.default_source_ref)
    TARGET_REF   = trimspace(var.default_target_ref)
  }))

  codify_bootstrap_scaffold_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-bootstrap-scaffold.sh.tftpl", {
    CLONE_DIR                 = local.target_clone_dir
    RULES_RUN_TESTS_SH_B64    = base64encode(local.rules_run_tests_sh)
    GITHUB_RULES_VALIDATE_B64 = base64encode(local.github_rules_validate_yml)
  }))

  codify_ci_gate_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-ci-gate.sh.tftpl", {
    TARGET_REPO         = local.default_target_repo_full
    CHECK_NAME          = trimspace(var.github_check_name)
    CI_TIMEOUT_SECONDS  = tostring(var.ci_gate_timeout_seconds)
    CLONE_DIR           = local.target_clone_dir
    PR_NUMBER           = "CODIFY_PR_NUMBER"
  }))

  codify_ci_push_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-ci-push.sh.tftpl", {
    CLONE_DIR   = local.target_clone_dir
    BRANCH      = "CODIFY_BRANCH"
    COMMIT_MSG  = "codify: ci repair"
  }))

  codify_scaffold_git_commit_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-scaffold-git-commit.sh.tftpl", {
    CLONE_DIR = local.target_clone_dir
  }))

  codify_scaffold_check_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-scaffold-check.sh.tftpl", {
    CLONE_DIR = local.target_clone_dir
  }))

  codify_branch_recover_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-branch-recover.sh.tftpl", {
    CLONE_DIR    = local.target_clone_dir
    TARGET_REPO  = local.default_target_repo_full
    BASE_BRANCH  = trimspace(var.default_base_branch)
  }))

  codify_handoff_verify_execute_series_template = trimspace(templatefile("${path.module}/templates/codify-handoff-verify.sh.tftpl", {
    CLONE_DIR   = local.target_clone_dir
    BASE_BRANCH = trimspace(var.default_base_branch)
  }))
}
