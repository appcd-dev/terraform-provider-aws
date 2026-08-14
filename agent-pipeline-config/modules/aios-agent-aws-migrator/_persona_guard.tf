# Hard rule — agent persona byte cap.
#
# Guild rejects any sg_agent register/update whose persona exceeds 15000 bytes
# (internal/guild/agentrouter/config.go: `len(c.Persona) > 15000`). Applying an
# oversized persona returns HTTP 500 from Guild, taints the resource, and
# every subsequent `tofu plan` re-runs the same broken update.
#
# This guard converts that runtime failure into a plan-time error: the
# precondition is evaluated against every `personas/*.md` file in this
# module, so an oversized file blocks `tofu plan` long before reaching
# `tofu apply`. Repo-wide enforcement also lives in:
#   - scripts/verify-persona-length.sh (wired into `make check` + CI persona-length job)
#   - tofu-provider-stackgen: sg_agent.persona has a schema-level maxlen:15000 validator
#
# Discovery uses fileset() so newly added persona files are picked up without
# touching this file. terraform_data has no side effects; it just hosts the
# precondition.
resource "terraform_data" "persona_length_guard" {
  for_each = fileset("${path.module}/personas", "*.md")

  input = each.value

  lifecycle {
    precondition {
      condition = length(file("${path.module}/personas/${each.value}")) <= 15000
      error_message = format(
        "Persona personas/%s is %d chars; Guild caps at 15000. Trim the file before applying.",
        each.value,
        length(file("${path.module}/personas/${each.value}")),
      )
    }
  }
}
