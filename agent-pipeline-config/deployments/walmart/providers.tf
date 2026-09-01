provider "sg" {
  stackgen_url      = var.stackgen_url
  stackgen_token    = var.stackgen_token
  project_id        = var.stackgen_project_id
  adopt_on_conflict = true
}
