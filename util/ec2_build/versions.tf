# This file does not follow the standards I hold myself to in a professional
# environment. There are a lot of non-deterministic things happening here, but
# these scratch machines are intended for my use, and usually for a very short
# time period.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

variable "region" {
  default = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (e.g., c6a.24xlarge, c7i.16xlarge)"
  type        = string
}

variable "architecture" {
  description = "CPU architecture: amd64 or arm64"
  type        = string
  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "Architecture must be either 'amd64' or 'arm64'."
  }
}

variable "use_spot" {
  description = "Use spot instances for cost savings (60-90% discount). Can be interrupted by AWS."
  type        = bool
  default     = true
}

variable "availability_zone_index" {
  description = "Index of availability zone to use. Try different values if spot requests timeout."
  type        = number
  default     = 0
  validation {
    condition     = var.availability_zone_index >= 0
    error_message = "Availability zone index must be >= 0."
  }
}

variable "gccarch_feature" {
  description = "GCC architecture feature for target system (e.g., gccarch-alderlake, gccarch-znver3, gccarch-skylake)"
  type        = string
  default     = ""
}

resource "random_id" "builder" {
  byte_length = 4
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Name               = "nix-ephemeral-builder-${var.architecture}-${random_id.builder.hex}"
      owner              = "kyle.ondy"
      ManagedBy          = "terraform-ephemeral-builder"
      AutoCleanup        = "true"
      Purpose            = "temporary-build"
    }
  }
}
