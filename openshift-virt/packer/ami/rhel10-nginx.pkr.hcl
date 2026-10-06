packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "source_ami" {
  type        = string
  description = "RHEL 10 source AMI ID"
}

variable "vpc_id" {
  type        = string
  description = "VPC to build in (required when the account has no default VPC)"
}

variable "subnet_id" {
  type        = string
  description = "Public subnet for the Packer builder instance"
}

variable "ami_name" {
  type    = string
  default = ""
}

locals {
  ami_name = var.ami_name != "" ? var.ami_name : "rhel10-nginx-${formatdate("YYYYMMDDhhmmss", timestamp())}"
}

source "amazon-ebs" "rhel10_nginx" {
  region                      = var.aws_region
  source_ami                  = var.source_ami
  instance_type               = "t3.medium"
  ssh_username                = "ec2-user"
  ami_name                    = local.ami_name
  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  ssh_interface               = "public_ip"

  tags = {
    Name    = local.ami_name
    Project = "rosa-end-to-end"
    Builder = "packer"
  }
}

build {
  name    = "rhel10-nginx-ami"
  sources = ["source.amazon-ebs.rhel10_nginx"]

  provisioner "shell" {
    script          = "${path.root}/../../scripts/provision-nginx.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "${path.root}/../../scripts/cleanup-image.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
