# Partial S3 backend. Bucket / key / region (and optional profile) are supplied at
# `tofu init` time via `-backend-config` — from GitHub Environment vars in CI, or
# from a local gitignored `backend.hcl` (see backend.hcl.example).
#
# Backend blocks cannot reference Terraform variables; partial config is the
# supported way to keep state location environment-specific.
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
