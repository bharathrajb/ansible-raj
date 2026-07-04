terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1" 
}

# Automatically query the latest official Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Get default VPC details
data "aws_vpc" "default" {
  default = true
}

# Create a Security Group with a dynamic name prefix
resource "aws_security_group" "ansible_sg" {
  name_prefix = "ansible-sg-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 1. Automatically generate a new secure private key locally
resource "tls_private_key" "pipeline_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 2. Register the generated public key with a dynamic name prefix
resource "aws_key_pair" "deployer_key" {
  key_name_prefix = "ansible-key-"
  public_key      = tls_private_key.pipeline_key.public_key_openssh

  # Save the private key to /root/.ssh/ pipeline node automatically
  provisioner "local-exec" {
    command = <<EOT
      mkdir -p /root/.ssh
      echo "${tls_private_key.pipeline_key.private_key_pem}" > /root/.ssh/ansible-key.pem
      chmod 400 /root/.ssh/ansible-key.pem
    EOT
  }
}

# Build the EC2 Instance target
resource "aws_instance" "target_node" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro" 
  key_name               = aws_key_pair.deployer_key.key_name
  vpc_security_group_ids = [aws_security_group.ansible_sg.id]

  tags = {
    Name = "AWS-Ansible-Target"
  }

  # Write out the structural updates back into your local ansible inventory automatically
  provisioner "local-exec" {
    command = <<EOT
      echo "[aws_targets]" > ../inventory
      echo "ec2-target ansible_host=${self.public_ip} ansible_user=ec2-user ansible_ssh_private_key_file=/root/.ssh/ansible-key.pem" >> ../inventory
    EOT
  }
}
