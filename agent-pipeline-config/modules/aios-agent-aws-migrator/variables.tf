variable "architect_persona_addendum" {
  description = "Optional deployment-specific guidance appended to the AWS migrator architect persona, for example how to translate natural-language operator intent into workflow inputs."
  type        = string
  default     = ""
}

variable "model_names" {
  description = "Optional ordered list of registered model names exposed to this module's agent. Leave empty to use Guild's built-in default model provider. Efficiency/mini models (names matching mini|flash|nano|haiku) are filtered out unless non_trivial_model_names is set."
  type        = list(string)
  default     = []
}

variable "non_trivial_model_names" {
  description = "Optional override for sg_agent.model_names on script-heavy sub-agents. When empty, model_names is filtered to drop efficiency-tier models (mini, flash, nano, haiku)."
  type        = list(string)
  default     = []
}

variable "subagent_task_type" {
  description = "Genie task_type for AWS-to-Azure IaC runner sub-agents (cloud2code scan, ingest, registry, converge). Use coding or planning for paste-heavy shell work; avoid terminal_calling/efficiency which routes to mini/flash models."
  type        = string
  default     = "coding"

  validation {
    condition     = contains(["coding", "planning", "tool_calling", "terminal_calling", "efficiency"], var.subagent_task_type)
    error_message = "subagent_task_type must be one of: coding, planning, tool_calling, terminal_calling, efficiency."
  }
}

variable "policy_ids" {
  description = "Policy IDs to attach (expects dangerous_ops from aios-policies)."
  type = object({
    dangerous_ops = string
  })
}

# =============================================================================
# Self-contained integration wiring (replaces the old `integration_names` map).
# Pass `github_secret_id` + `aws_secret_id` for GitHub/AWS MCP integrations.
# Shell / tofu / git / state download run on the module's remote runner — wire
# git + cloud credentials on the runner host (env, K8s Secret, or mothership sync).
# =============================================================================

variable "extra_agent_integration_names" {
  description = "Additional pre-existing Guild integration names to keep attached to the architect agent. Use for operator-added integrations that this module should preserve."
  type        = list(string)
  default     = []
}

variable "github_secret_id" {
  description = <<-EOT
    Optional `sg_secret` ID for the GitHub PAT used by `gh api` MCP tools.
    When set (and `existing_github_integration_name` is empty), this module provisions
    its own GitHub Guild integration internally. **`git clone` / `git push`** for IaC
    repos run on the **remote runner** — mount the same PAT on the runner env as
    `GIT_TOKEN` / `GIT_HOST` / `GIT_USERNAME` (see README).

    One of `github_secret_id` / `existing_github_integration_name` must be
    provided. The same secret can be reused across agent modules (one Vault
    entry per tenant).
  EOT
  type        = string
  default     = ""
}

variable "aws_secret_id" {
  description = <<-EOT
    Optional `sg_secret` (`CloudProvider`/`aws`) ID holding AWS role-assume
    metadata for the read-only role the agent uses to inspect monolith state
    on S3 / DynamoDB / etc. When set (and `existing_aws_integration_name` is
    empty), this module provisions its own AWS Guild integration internally.

    Forward [`aios-integration-aws`](../aios-integration-aws).secret_id here,
    or any pre-existing AWS Guild secret. One of `aws_secret_id` /
    `existing_aws_integration_name` must be provided.
  EOT
  type        = string
  default     = ""
}

variable "existing_github_integration_name" {
  description = <<-EOT
    Optional Guild integration name to use for `gh api` calls instead of the
    module-provisioned GitHub integration. When set (non-empty), this module
    does NOT create its own GitHub Guild integration container — it attaches
    the named integration to the agent. Combine with a shared `github_secret_id`
    when many agent modules use the same tenant-level PAT.
  EOT
  type        = string
  default     = ""
}

variable "existing_aws_integration_name" {
  description = <<-EOT
    Optional Guild integration name to use for the AWS MCP sandbox instead of
    the module-provisioned one. When set (non-empty), this module does NOT
    create its own AWS integration. Typical sharing pattern for SREs and IaC
    agents that already have an `aws-production` (or equivalent) integration.
  EOT
  type        = string
  default     = ""
}

variable "existing_azure_integration_name" {
  description = <<-EOT
    Optional Guild Azure integration name to attach to the architect agent
    (MCP tools). Live tofu plan on the remote runner still needs ARM_* env —
    pass `runner_azure_env_secret_id` or typed `azure` in
    `remote_runner_typed_secret_refs`.
  EOT
  type        = string
  default     = ""
}

variable "runner_azure_env_secret_id" {
  description = <<-EOT
    Pre-existing vault secret UUID whose metadata includes flat ARM_* keys
    (`ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`)
    for remote-runner live tofu plan. Bound to typed slot `azure` when
    `remote_runner_secret_sync_enabled`.
  EOT
  type        = string
  default     = ""
}

variable "require_azure_live_plan" {
  description = <<-EOT
    When true, azure-iac-validate fails if live tofu plan cannot run
    (`azure_plan_status=skipped:missing_credentials` is a hard fail).
    When null (default), requires live plan automatically if
    `runner_azure_env_secret_id` or `existing_azure_integration_name` is set;
    otherwise keeps the demo soft-skip for missing credentials.
  EOT
  type        = bool
  nullable    = true
  default     = null
}

variable "existing_gcp_integration_name" {
  description = <<-EOT
    Optional Guild GCP integration name to attach to the architect agent
    (MCP tools). Live tofu plan on the remote runner still needs GCP env —
    pass `runner_gcp_env_secret_id` or typed `gcp` in
    `remote_runner_typed_secret_refs`.
  EOT
  type        = string
  default     = ""
}

variable "runner_gcp_env_secret_id" {
  description = <<-EOT
    Pre-existing vault secret UUID whose metadata includes GCP ADC keys
    (`GOOGLE_APPLICATION_CREDENTIALS_JSON`, `GCP_PROJECT_ID`, optional `GCP_REGION`)
    for remote-runner live tofu plan. Bound to typed slot `gcp` when
    `remote_runner_secret_sync_enabled`.
  EOT
  type        = string
  default     = ""
}

variable "require_gcp_live_plan" {
  description = <<-EOT
    When true, gcp-iac-validate fails if live tofu plan cannot run
    (`gcp_plan_status=skipped:missing_credentials` is a hard fail).
    When null (default), requires live plan automatically if
    `runner_gcp_env_secret_id` or `existing_gcp_integration_name` is set;
    otherwise keeps the demo soft-skip for missing credentials.
  EOT
  type        = bool
  nullable    = true
  default     = null
}

variable "name_suffix" {
  description = <<-EOT
    Optional suffix appended to the agent / workflow / runbook / webhook /
    nested integration resource names so multiple instances of this module can
    coexist in one Guild tenant without colliding (e.g. `prod` vs `staging`).
    Empty by default. Forwarded into SOP `templatefile()` calls via
    `module_prefix` so the SOP text references the correct module-prefixed
    tool names at runtime.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]*$", var.name_suffix))
    error_message = "name_suffix must be empty or contain only letters, digits, and hyphens."
  }
}

# =============================================================================
# Remote runner (required — primary shell / tofu / state-download execution)
# =============================================================================

variable "remote_runner_name" {
  description = <<-EOT
    Guild remote runner name. Defaults to `<module_prefix>-runner[-<suffix>]` when empty.
    Shell subagents use `<name>_execute_command|series|parallel|create_files`.
    Set `create_remote_runner = true` to register `sg_remote_runner` (provider **>= 0.1.25**)
    and surface CLI/Helm install commands in module outputs.
  EOT
  type        = string
  default     = ""
}

variable "runner_work_home" {
  description = <<-EOT
    Scratch directory root on the remote runner host (per-run dirs are `<runner_work_home>/.<workflow_run_id>/`).
    Must match aiden-runner `HOME` or the user the runner process uses. Default `/home/runner`.
  EOT
  type        = string
  default     = ""
}

variable "create_remote_runner" {
  description = "When true, creates `sg_remote_runner` via `aios-remote-runner`. Default true for new installs."
  type        = bool
  default     = true
}

variable "remote_runner_description" {
  description = "Runner description when `create_remote_runner` is true."
  type        = string
  default     = ""
}

variable "remote_runner_labels" {
  description = "Optional runner labels when `create_remote_runner` is true."
  type        = map(string)
  default     = {}
}

variable "remote_runner_attach_to_agent" {
  description = <<-EOT
    When true, sets `remote_runners` on the Guild agent (default true). The runner must be **online**
    before workflows invoke remote runner execute tools.
  EOT
  type        = bool
  default     = true
}

variable "runner_git_token" {
  description = <<-EOT
    GitHub/GitLab HTTPS token for **remote runner** `git clone` / `gh pr` (not the `gh api` MCP integration).
    When non-empty, provisions a vault secret with `GIT_TOKEN`/`GIT_HOST`
    metadata and binds it on the runner typed `github` slot via `sg_remote_runner_secrets`,
    including when this module reuses an existing runner.
    Use **repo:write** when IaC PR creation is required. Mutually exclusive with `runner_git_env_secret_id`.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "runner_git_host" {
  description = "Git host for runner sync secret metadata (no scheme), e.g. github.com."
  type        = string
  default     = "github.com"
}

variable "runner_git_username" {
  description = "Git HTTPS username paired with runner_git_token (GitHub convention: x-access-token)."
  type        = string
  default     = "x-access-token"
}

variable "runner_git_env_secret_id" {
  description = <<-EOT
    Pre-existing vault secret UUID whose metadata is already flat env keys (`GIT_TOKEN`, `GIT_HOST`, …).
    Used when `runner_git_token` is empty. Bound to typed slot `github` when `remote_runner_secret_sync_enabled`.
  EOT
  type        = string
  default     = ""
}

variable "runner_aws_access_key_id" {
  description = "AWS access key for runner S3 state download / tofu (synced via typed `aws` slot when set with secret key)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "runner_aws_secret_access_key" {
  description = "AWS secret access key paired with runner_aws_access_key_id."
  type        = string
  default     = ""
  sensitive   = true
}

variable "runner_aws_region" {
  description = "AWS region written into runner sync secret metadata."
  type        = string
  default     = "us-east-1"
}

variable "runner_aws_env_secret_id" {
  description = "Pre-existing vault secret UUID with flat `AWS_*` metadata for runner sync when inline AWS keys are omitted."
  type        = string
  default     = ""
}

variable "remote_runner_secret_sync_enabled" {
  description = "When true, applies sg_remote_runner_secrets when typed/generic refs resolve non-empty."
  type        = bool
  default     = true
}

variable "remote_runner_typed_secret_refs" {
  description = "Extra typed vault bindings (subcategory → secret UUID) merged with module-provisioned git/aws runner secrets."
  type        = map(string)
  default     = {}
}

variable "remote_runner_generic_secret_ref_ids" {
  description = "Generic vault secret UUIDs merged into runner env at mothership sync."
  type        = list(string)
  default     = []
}

variable "remote_runner_secrets_sync_interval_seconds" {
  description = "aiden-runner secrets sync poll interval (default 60s)."
  type        = number
  default     = 60
}

variable "remote_runner_script_pack_sync_enabled" {
  description = "When true, creates a vault secret with SCRIPT_PACK_* metadata and binds it on the runner via sg_remote_runner_secrets so the pack refreshes without redeploying the runner container."
  type        = bool
  default     = true
}

variable "runner_script_pack_env_secret_id" {
  description = "Pre-existing vault secret UUID with flat SCRIPT_PACK_* metadata. When set, the module does not create runner_script_pack."
  type        = string
  default     = ""
}

variable "script_pack_tarball_url" {
  description = "HTTPS URL of the script-pack tarball for runner sync. Empty uses GitHub release pack-<script_pack_version>/script-pack.tar.gz on script_pack_release_repo."
  type        = string
  default     = ""
}

variable "script_pack_release_repo" {
  description = "GitHub owner/repo for default script pack release downloads (private repos need GIT_TOKEN on the runner)."
  type        = string
  default     = "Walmart-StackGen/Nile-Factory"
}

variable "enable_cce" {
  description = "When true, attaches optional CCE iac-alignment runbook (requires `cce` on the remote runner image when used)."
  type        = bool
  default     = true
}

variable "application_repo_url" {
  description = "Optional GitHub URL of the application repo to CCE-scan alongside Terraform state split (empty skips app CCE)."
  type        = string
  default     = ""
}

variable "enable_github_webhook" {
  description = "When true, creates sg_webhook targeting the primary split workflow (GitHub issue/PR ingress)."
  type        = bool
  default     = false
}

variable "workflow_skill_refs" {
  description = <<-EOT
    Optional extra skill_refs per primary-workflow stage binding. Keys:
    "aws-cloud-discovery::<stage_id>" where stage_id is one of:
    runner-capability-preflight, preflight-blocked-gate, cloud2code-scan-aws,
    cloud2code-scan-loop, scan-blocked-gate, ingest-and-split, ingest-split-loop,
    ingest-blocked-gate, registry-and-import-codegen, shell-converge-matrix,
    shell-converge-loop, converge-blocked-gate, orphans-secondary-pipeline,
    final-gate-and-memory.
    Destination workflows use "azure-migration-pr::<stage_id>" / "gcp-migration-pr::<stage_id>".
    Legacy keys (ingest-monolith, discover-db-anchors, hcl-hydrate-per-group,
    multi-shard-plan-convergence) are merged via try() fallbacks
    on the new stage ids — map extra skills to the v2 stage ids above.
    Note: `shell-converge-matrix` may GO_BACK via `shell-converge-loop` when the
    validation sentinel is missing/truncated; a conclusive quoted true|false exits
    so Guild's stage visit cap cannot abort the run (session e210eccd).
    `orphans-secondary-pipeline` handles non-hydratable addresses before final fan-in.
    Blocked gates (`*-blocked-gate`) are `conditional_skip` only — skill_refs on those ids are unused.
    **Avoid duplicating runbooks:** each stage already has `runbook_refs` + `skill_refs` from this module.
    Adding the same `*-sop` name here forces Guild to prepend `[Skills] load_skill` for content already
    inlined under `[Runbook Context]` — only add **extra** skills that are not the runbook SOPs.
  EOT
  type        = map(list(string))
  default     = {}
}

variable "secondary_workflow_skill_refs" {
  description = <<-EOT
    Optional extra skill_refs per secondary orphan-module workflow stage. Keys:
    "aws-migrator-orphan-iac-module-authoring::<stage_id>".
    Prefer not duplicating runbook SOP names already attached via `runbook_refs` on that workflow.
  EOT
  type        = map(list(string))
  default     = {}
}

variable "max_convergence_iterations" {
  description = "Cap for outer count/plan convergence loop stages. Keep at or below Guild's stage visit cap (5) so GO_BACK cannot abort the workflow (session e210eccd). Inner tfstate split candidate tuning is controlled by tfstate_decomposer_max_tuning_iterations / DBSPLIT_MAX_TUNING_ITERATIONS."
  type        = number
  default     = 4

  validation {
    condition     = var.max_convergence_iterations >= 1 && var.max_convergence_iterations <= 20
    error_message = "max_convergence_iterations must be between 1 and 20."
  }
}

variable "max_governance_iterations" {
  description = "Cap for azure/gcp iac-governance-conform loops. Each iteration refreshes living Nile docs, rebuilds the decision tree, and re-verifies generated IaC. Prefer *_iac_governance_ok=true; destination PR still opens with TODOs if residuals remain after this cap."
  type        = number
  default     = 5

  validation {
    condition     = var.max_governance_iterations >= 1 && var.max_governance_iterations <= 20
    error_message = "max_governance_iterations must be between 1 and 20."
  }
}

variable "max_validate_iterations" {
  description = "Cap for azure/gcp iac-validate remediates loops. Agent patches HCL / vars between visits until validation_ok=true or a terminal blocker (missing creds when required, runner tofu missing). Soft-opens destination PR after this cap with remarks."
  type        = number
  default     = 5

  validation {
    condition     = var.max_validate_iterations >= 1 && var.max_validate_iterations <= 20
    error_message = "max_validate_iterations must be between 1 and 20."
  }
}

variable "nile_governance_repo_url" {
  description = "Living Nile governance git remote refreshed at the start of each governance-conform run. Default is Walmart-StackGen/Governance-and-Policy. The docs/nile-governance submodule is an optional human pin, not the runtime source."
  type        = string
  default     = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
}

variable "nile_governance_ref" {
  description = "Git ref to checkout when refreshing living Nile governance docs (default main)."
  type        = string
  default     = "main"
}

variable "nile_rules_repo_url" {
  description = "Nile-Factory git remote whose rules/ Rego packs are evaluated against terraform plan JSON during governance-conform. Default is Walmart-StackGen/Nile-Factory."
  type        = string
  default     = "https://github.com/Walmart-StackGen/Nile-Factory.git"
}

variable "nile_rules_ref" {
  description = "Git ref for Nile-Factory rules/ when running OPA governance checks (default main; use PR branch SHA while codifying)."
  type        = string
  default     = "main"
}

variable "default_grouping_strategy" {
  description = <<-EOT
    Default `grouping_strategy` when workflow inputs omit it. Use `tfstate_monolith_decomposer` for
    layered three-tier monolith decomposition without an artificial per-group size cap (pair with
    `default_max_resources_per_appstack = 0`). Large monoliths (>5000 resources) auto-promote to
    these defaults when the operator does not override grouping in the webhook payload.
  EOT
  type        = string
  default     = "tfstate_monolith_decomposer"

  validation {
    condition = contains(
      [
        "tfstate_monolith_decomposer",
        "layered_three_tier",
        "policy_first",
        "connectivity",
        "connectivity_capped",
        "tag_seeded_connectivity",
        "tag_seeded_connectivity_capped",
        "type_chunk",
      ],
      var.default_grouping_strategy,
    )
    error_message = "default_grouping_strategy must be tfstate_monolith_decomposer/layered_three_tier or a supported legacy allocate_manifest.py strategy."
  }
}

variable "default_max_resources_per_appstack" {
  description = <<-EOT
    Default per-group resource ceiling when workflow inputs omit legacy `max_resources_per_appstack`.
    **0 means unlimited** (no BFS cap-split or seed-bin chunking beyond natural connectivity).
    Positive integers cap shard size (e.g. 120 for smaller plan matrices).
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.default_max_resources_per_appstack >= 0 && var.default_max_resources_per_appstack <= 100000
    error_message = "default_max_resources_per_appstack must be between 0 (unlimited) and 100000."
  }
}

variable "default_iac_repository_url" {
  description = <<-EOT
    Fallback clone URL when workflow/webhook inputs omit `iac_repository_url`. Empty means the
    architect must receive `iac_repository_url` in the trigger payload (schedule JSON includes it).
  EOT
  type        = string
  default     = ""
}

variable "default_branch" {
  description = "Fallback git branch for IaC push when workflow inputs omit `default_branch`."
  type        = string
  default     = "main"
}

variable "azure_only_source_branch" {
  description = <<-EOT
    Git branch the azure-only workflow clones for prior discovery IaC (`aws/groups`, `aws/artifacts`).
    Required for azure-only smoke/demo runs; leave empty only when that workflow is unused.
  EOT
  type        = string
  default     = ""
}

variable "gcp_only_source_branch" {
  description = <<-EOT
    Git branch the gcp-only workflow clones for prior discovery IaC (`aws/groups`, `aws/artifacts`).
    Required for gcp-only smoke/demo runs; leave empty only when that workflow is unused.
  EOT
  type        = string
  default     = ""
}

variable "subagent_budgets" {
  description = <<-EOT
    Optional overrides for create_agent subagent budgets (Guild clamps max_llm_calls to [8, 60]
    and max_tool_iterations to [40, 50]). Raise script_runner_max_llm_calls when ingest-and-split
    hits "max LLM calls exceeded" during download/split-manifest; raise registry_codegen_max_llm_calls
    for large-state scaffold + show -json chunking.
  EOT
  type = object({
    script_runner_max_llm_calls                = optional(number)
    script_runner_max_tool_iterations          = optional(number)
    script_runner_timeout_seconds              = optional(number)
    registry_codegen_max_llm_calls             = optional(number)
    registry_codegen_max_tool_iterations       = optional(number)
    registry_codegen_timeout_seconds           = optional(number)
    hcl_hydrate_batch_max_llm_calls            = optional(number)
    hcl_hydrate_batch_max_tool_iterations      = optional(number)
    hcl_hydrate_batch_timeout_seconds          = optional(number)
    plan_convergence_batch_max_llm_calls       = optional(number)
    plan_convergence_batch_max_tool_iterations = optional(number)
    plan_convergence_batch_timeout_seconds     = optional(number)
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Optional webhook ingress URLs (`POST /api/v1/webhooks/trigger`)
# ---------------------------------------------------------------------------
variable "webhook_trigger_base_url" {
  description = <<-EOT
    Optional StackGen HTTP API origin (e.g. `https://walmart.cloud.stackgen.com`). When set,
    outputs include `webhook_trigger_endpoint` and, when the GitHub ingress webhook token
    exists, `webhook_ingress_payload_url` — a full URL with `apiKey=` for GitHub "Payload URL"
    and other senders that cannot set `Authorization: Bearer`. Leave empty (default) to omit.
  EOT
  type        = string
  default     = ""
}

variable "webhook_trigger_org_id" {
  description = <<-EOT
    Optional `orgId` query parameter appended to `webhook_ingress_payload_url` when
    `webhook_trigger_base_url` is set. Use the same StackGen organization / project id
    you pass as the provider `project_id` for this Guild tenant.
  EOT
  type        = string
  default     = ""
}
