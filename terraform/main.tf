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

# 1. Core Network & Base Image Queries
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

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

# 2. Application Load Balancer Security Profile
resource "aws_security_group" "alb_sg" {
  name_prefix = "alb-sg-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Target EC2 Cluster Instance Security Profile
resource "aws_security_group" "instance_sg" {
  name_prefix = "instance-sg-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4. Cryptographic Key Pairing & Safe SSM parameter Storage
resource "tls_private_key" "pipeline_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deployer_key" {
  key_name_prefix = "ansible-key-"
  public_key      = tls_private_key.pipeline_key.public_key_openssh
}

resource "aws_ssm_parameter" "ssh_private_key" {
  name        = "/pipeline/ansible_private_key"
  description = "Managed private deployment key"
  type        = "SecureString"
  value       = tls_private_key.pipeline_key.private_key_pem
}

# 5. External Load Balancer Core Engine
resource "aws_lb" "external_alb" {
  name               = "pipeline-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

# Target Routing Group A: Application Web Service
resource "aws_lb_target_group" "alb_target_group" {
  name     = "pipeline-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Target Routing Group B: Grafana Metric Workspace
resource "aws_lb_target_group" "grafana_tg" {
  name     = "grafana-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/api/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 20
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Public Inbound Access Control Interfaces
resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.external_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_target_group.arn
  }
}

resource "aws_lb_listener" "grafana_listener" {
  load_balancer_arn = aws_lb.external_alb.arn
  port              = "3000"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana_tg.arn
  }
}

# 6. EC2 Launch Template Config (With Enhanced gp3 Node Volumes)
resource "aws_launch_template" "asg_template" {
  name_prefix   = "asg-template-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.deployer_key.key_name

  # Upgrading root system block layout map allocation to 20GB gp3
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.instance_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ASG-Docker-Host"
    }
  }
}

# 7. Dynamic Cluster Scaling System Environment
resource "aws_autoscaling_group" "pipeline_asg" {
  name_prefix         = "pipeline-asg-"
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  target_group_arns   = [aws_lb_target_group.alb_target_group.arn, aws_lb_target_group.grafana_tg.arn]
  vpc_zone_identifier = data.aws_subnets.default.ids

  launch_template {
    id      = aws_launch_template.asg_template.id
    version = "$Latest"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Output Configuration Data Element
output "alb_dns_name" {
  value       = aws_lb.external_alb.dns_name
  description = "Public URL for your web application and metrics panel"
}
