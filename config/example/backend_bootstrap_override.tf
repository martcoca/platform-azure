# Copy this file to ./backend_bootstrap_override.tf for the first local apply only.
# The root copy is ignored. Remove it before running `tofu init -migrate-state`.
terraform {
  backend "local" {}
}
