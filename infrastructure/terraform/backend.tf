# The bucket, region, and lock table are project-specific (a state bucket
# name must be globally unique, so it can't be hardcoded into a template)
# and get supplied at `terraform init` time via `-backend-config=backend.hcl`.
# Run scripts/setup-terraform-backend.sh once to create that backend and
# generate backend.hcl — see the Terraform section of the root README.
#
# See scripts/compute-deploy-name.sh.
terraform {
  backend "s3" {
    encrypt = true
  }
}
