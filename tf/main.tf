terraform {
  required_version = ">= 1.15"

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
