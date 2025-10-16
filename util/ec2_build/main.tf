# SSH Key Generation
resource "tls_private_key" "builder" {
  algorithm = "ED25519"
}

resource "random_pet" "key_name" {
  length = 2
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.builder.private_key_openssh
  filename        = "${path.module}/builder-${random_pet.key_name.id}.key"
  file_permission = "0600"
}

resource "aws_key_pair" "builder" {
  key_name   = "builder-${random_pet.key_name.id}"
  public_key = tls_private_key.builder.public_key_openssh
}

data "http" "myip" {
  url = "https://api.ipify.org"
}

data "aws_ami" "nixos_amd64" {
  count       = var.architecture == "amd64" ? 1 : 0
  most_recent = true

  filter {
    name   = "name"
    values = ["nixos/*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["427812963091"] # Official NixOS account
}

data "aws_ami" "nixos_arm64" {
  count       = var.architecture == "arm64" ? 1 : 0
  most_recent = true

  filter {
    name   = "name"
    values = ["nixos/*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["427812963091"] # Official NixOS account
}

resource "aws_instance" "this" {
  ami           = var.architecture == "amd64" ? data.aws_ami.nixos_amd64[0].id : data.aws_ami.nixos_arm64[0].id
  instance_type = var.instance_type
  key_name      = aws_key_pair.builder.key_name
  subnet_id     = aws_subnet.public.id
  vpc_security_group_ids = [
    aws_security_group.allow_all_egress.id,
    aws_security_group.allow_ssh.id,
  ]

  root_block_device {
    encrypted   = true
    volume_size = 500
    volume_type = "gp3"
    iops        = 16000
    throughput  = 1000
  }

  # Only set shutdown behavior for on-demand instances (not supported for spot)
  instance_initiated_shutdown_behavior = var.use_spot ? null : "terminate"

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price                      = ""
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  metadata_options {
    http_tokens = "required"
  }

  user_data = templatefile("${path.module}/user-data.nix.tpl", {
    gccarch_feature = var.gccarch_feature
  })
}

resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh"
  description = "Allow SSH inbound connections"
  vpc_id      = aws_vpc.builder.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${data.http.myip.response_body}/32"]
  }
}

resource "aws_security_group" "allow_all_egress" {
  name        = "allow_all_egress"
  description = "Allow all outgoing conncetions"
  vpc_id      = aws_vpc.builder.id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

# VPC and Networking
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "builder" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "builder" {
  vpc_id = aws_vpc.builder.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.builder.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[var.availability_zone_index]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.builder.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.builder.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

output "ec2_dns" {
  value       = aws_instance.this.public_dns
  description = "Public DNS name of the builder instance"
}

output "instance_id" {
  value       = aws_instance.this.id
  description = "Instance ID for emergency cleanup"
}

output "keypair" {
  value       = aws_key_pair.builder.key_name
  description = "Name of the SSH keypair"
}

output "keypair_file" {
  value       = local_sensitive_file.private_key.filename
  description = "Path to the private key file"
}

output "user_data_rendered" {
  value = templatefile("${path.module}/user-data.nix.tpl", {
    gccarch_feature = var.gccarch_feature
  })
  description = "Rendered user-data configuration for debugging"
}
