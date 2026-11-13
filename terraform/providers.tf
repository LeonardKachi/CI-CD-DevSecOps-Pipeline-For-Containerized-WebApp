provider "aws" {
  region = var.region

  # Every resource that supports tags gets these, so anything in the account can
  # be traced back to this project and to Terraform.
  default_tags {
    tags = {
      Project   = var.project
      Component = "application"
      ManagedBy = "terraform"
    }
  }
}
