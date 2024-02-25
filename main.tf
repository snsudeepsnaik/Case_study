# main.tf file for the entire configuration

provider "aws" {
  region = "us-east-1" # Change to your desired AWS region
  profile = "zantac_poc_profile"
  
}

# Create VPC
resource "aws_vpc" "zantac_poc_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "zantac_poc_vpc"
  }
}

# Create Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.zantac_poc_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a" # Availability Zone
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet"
  }
}

# Create Private Subnets
resource "aws_subnet" "private_subnet1" {
  vpc_id                  = aws_vpc.zantac_poc_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b" # Availability Zone

  tags = {
    Name = "PrivateSubnet1"
  }
}

resource "aws_subnet" "private_subnet2" {
  vpc_id                  = aws_vpc.zantac_poc_vpc.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "us-east-1c" # Availability Zone

  tags = {
    Name = "PrivateSubnet2"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "zantac_poc_igw" {
  vpc_id = aws_vpc.zantac_poc_vpc.id
}

# Create Route Table for Public Subnet
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.zantac_poc_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.zantac_poc_igw.id
  }
}

# Associate Public Subnet with Public Route Table
resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# Create Security Groups
resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.zantac_poc_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "LBSecurityGroup"
  }
}

resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.zantac_poc_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    security_group_ids = [aws_security_group.lb_sg.id]
  }

  tags = {
    Name = "WebSecurityGroup"
  }
}

# Create IAM User
resource "aws_iam_user" "webserver_restart_user" {
  name = "webserver_restart_user"
}

#Custom Policy to only restart an instance.
data "aws_iam_policy_document" "restart_policy" {
  source_json = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:StartInstances",
          "ec2:StopInstances"
        ],
        "Resource": "*"
      }
    ]
  }
  EOF
}

resource "aws_iam_policy" "restart_policy" {
  name        = "RestartPolicy"
  description = "Custom policy to restart web server"
  policy      = data.aws_iam_policy_document.restart_policy.json
}

# Attach IAM Policy to User
resource "aws_iam_user_policy_attachment" "webserver_restart_user_policy" {
  user       = aws_iam_user.webserver_restart_user.name
  policy_arn = aws_iam_policy.restart_policy.arn # Policy attached to user to restart web servers.
}

# Create Launch Template
resource "aws_launch_template" "web_launch_template" {
  name = "web-launch-template"
  image_id = "custom_AMI" # Specify the assumed custom AMI with nginx pre-installed and the default port changed to 8080 instead of 80
  instance_type = "t2.micro" # Specify the desired instance type
  security_groups = aws_security_group.web_sg.id
  key_name = "keypair_name"
  
#Block device configuration.
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
	  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }
  }

#  user_data = <<-EOF
#              #!/bin/bash
#              sed -i 's/80/8080/' /etc/nginx/nginx.conf
#              service nginx restart
#              EOF

  lifecycle {
    create_before_destroy = true
  }
}

# Create Auto Scaling Group
resource "aws_autoscaling_group" "web_autoscaling_group" {
  desired_capacity     = 1
  max_size             = 2
  min_size             = 1
  launch_template = aws_launch_template.web_launch_template.id
  health_check_type = "ELB"
  force_delete = true
  default_cooldown = 300
  vpc_zone_identifier  = [aws_subnet.private_subnet1.id, aws_subnet.private_subnet2.id]

  tag {
    key                 = "Name"
    value               = "WebServer"
    propagate_at_launch = true
  }
}

# Create Load Balancer
resource "aws_lb" "web_lb" {
  name               = "web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [aws_subnet.public_subnet.id]

  enable_deletion_protection = false
}

# Create Target Group
resource "aws_lb_target_group" "web_target_group" {
  name     = "web-target-group"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.zantac_poc_vpc.id
}

# Attach Target Group to Auto Scaling Group
resource "aws_autoscaling_attachment" "web_autoscaling_attachment" {
  autoscaling_group_name = aws_autoscaling_group.web_autoscaling_group.name
  alb_target_group_arn   = aws_lb_target_group.web_target_group.arn
}

# Output Load Balancer DNS Name
output "load_balancer_dns_name" {
  value = aws_lb.web_lb.dns_name
}
