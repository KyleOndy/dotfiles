terraform {
  required_version = ">= 1.15"

  # The bucket is state.tf's, written out because a backend block cannot
  # reference a resource.
  backend "s3" {
    bucket       = "ondy-tfstate-united-gobbler"
    key          = "dotfiles/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = ["436428857397"]
  default_tags {
    tags = {
      owner      = "kyle@ondy.org"
      managed_by = "https://github.com/KyleOndy/dotfiles/tf"
    }
  }
}
