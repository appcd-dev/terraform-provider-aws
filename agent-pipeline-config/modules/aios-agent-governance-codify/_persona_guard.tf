# Guild caps sg_agent.persona at 15000 bytes. Block oversize personas at plan time.
resource "terraform_data" "persona_length_guard" {
  for_each = fileset("${path.module}/personas", "*.md.tftpl")

  input = each.value

  lifecycle {
    precondition {
      condition = length(file("${path.module}/personas/${each.value}")) <= 15000
      error_message = format(
        "Persona personas/%s is %d chars; Guild caps at 15000. Trim before applying.",
        each.value,
        length(file("${path.module}/personas/${each.value}")),
      )
    }
  }
}
