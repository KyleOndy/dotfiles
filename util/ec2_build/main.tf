# This file does not follow the standards I hold myself to in a professional
# environment. There are a lot of non-deterministic things happening here, but
# these scratch machines are intended for my use, and usually for a very short
# time period.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

variable "region" {
  default = "us-east-1"
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Name  = "nix aarch64 builder"
      owner = "kyle.ondy"
      #eol   = formatdate("YYYY-MM-DD", timeadd(timestamp(), "8h"))
    }
  }
}


module "key" {
  source      = "git@github.com:KyleOndy/terraform-aws-local-keypair.git?ref=v0.1.0"
  name_prefix = "scratch"
}

data "aws_ami" "nixos" {
  most_recent = true

  filter {
    name   = "name"
    values = ["NixOS-*-aarch64-linux"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["080433136561"]
}

resource "aws_instance" "this" {
  ami           = data.aws_ami.nixos.id
  instance_type = "c6g.16xlarge" # 16xlarge for max build!
  key_name      = module.key.name
  subnet_id     = module.dynamic_subnets.public_subnet_ids[0]
  vpc_security_group_ids = [
    aws_security_group.allow_all_egress.id,
    aws_security_group.allow_ssh.id,
  ]

  root_block_device {
    volume_size = "200"
  }

  instance_initiated_shutdown_behavior = "terminate"

  #user_data_base64 = filebase64("${path.module}/user_data.nix")

  lifecycle {
    # nixos can install while waiting for old instance to be destroyed
    create_before_destroy = true
  }
}

module "myip" {
  source  = "4ops/myip/http"
  version = "1.0.0"
}

resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh"
  description = "Allow SSH inbound connections"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${module.myip.address}/32"]
  }
}

resource "aws_security_group" "allow_all_egress" {
  name        = "allow_all_egress"
  description = "Allow all outgoing conncetions"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

# todo: roll my own VPC module
module "vpc" {
  source     = "cloudposse/vpc/aws"
  version    = "0.28.1"
  cidr_block = "10.0.0.0/16"
}

# todo: roll my own subnet module
module "dynamic_subnets" {
  source              = "cloudposse/dynamic-subnets/aws"
  version             = "0.39.7"
  nat_gateway_enabled = false
  availability_zones  = [data.aws_availability_zones.available.names[0]]
  vpc_id              = module.vpc.vpc_id
  igw_id              = module.vpc.igw_id
  cidr_block          = "10.0.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}

output "ec2_dns" {
  value = aws_instance.this.public_dns
}

output "keypair" {
  value = module.key.name
}
