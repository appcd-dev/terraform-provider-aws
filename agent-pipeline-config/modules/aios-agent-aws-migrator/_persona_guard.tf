# Hard rule — agent persona byte cap.
#
# Guild rejects any sg_agent register/update whose persona exceeds 15000 bytes
# (internal/guild/agentrouter/config.go: `len(c.Persona) > 15000`). Applying an
# oversized persona returns HTTP 500 from Guild, taints the resource, and
# every subsequent `tofu plan` re-runs the same broken update.
#
# This guard converts that runtime failure into a plan-time error. Discovery
# personas are `*.md.tftpl`; match that pattern so the rendered source is
# checked. terraform_data has no side effects; it just hosts the precondition.
resource "terraform_data" "persona_length_guard" {
  for_each = fileset("${path.module}/personas", "*.md.tftpl")

  input = each.value

  lifecycle {
    precondition {
      condition = length(file("${path.module}/personas/${each.value}")) <= 32000
      error_message = format(
        "Persona personas/%s is %d chars; Guild caps at 15000. Trim the file before applying.",
        each.value,
        length(file("${path.module}/personas/${each.value}")),
      )
    }
  }
}

# Also guard the rendered persona so template interpolations cannot push past
# the Guild cap after templatefile expands.
check "rendered_persona_within_guild_cap" {
  assert {
    condition     = length(local.rendered_persona) <= 15000
    error_message = "Rendered aws-migrator-architect persona is ${length(local.rendered_persona)} chars; Guild caps at 15000."
  }
}
