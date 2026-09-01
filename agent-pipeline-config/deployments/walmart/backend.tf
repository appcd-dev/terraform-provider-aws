# Local state by default — phase 1 apply needs only a StackGen PAT.
# For shared/CI state, copy backend.hcl.example → backend.hcl and re-init.
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
