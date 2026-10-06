packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
  }
}

variable "base_qcow2" {
  type        = string
  description = "Path to the RHEL 10 KVM guest qcow2 base image"
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to SSH private key injected via cloud-init"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key injected via cloud-init"
}

variable "output_directory" {
  type    = string
  default = ""
}

locals {
  output_directory = var.output_directory != "" ? var.output_directory : "${path.root}/../../output"
  cloud_user_data = <<-EOT
    #cloud-config
    users:
      - name: cloud-user
        sudo: ALL=(ALL) NOPASSWD:ALL
        groups: wheel
        shell: /bin/bash
        ssh_authorized_keys:
          - ${var.ssh_public_key}
    ssh_pwauth: false
    EOT
  cloud_meta_data = <<-EOT
    instance-id: rhel10-nginx-packer
    local-hostname: rhel10-nginx
    EOT
}

source "qemu" "rhel10_nginx" {
  iso_url      = var.base_qcow2
  iso_checksum = "none"
  disk_image   = true

  output_directory = local.output_directory
  vm_name          = "rhel10-nginx.qcow2"
  format           = "qcow2"

  accelerator = "kvm"
  memory      = 2048
  cpus        = 2
  disk_size   = "20G"
  headless    = true

  ssh_username         = "cloud-user"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "20m"

  cd_label = "cidata"
  cd_content = {
    "/user-data" = local.cloud_user_data
    "/meta-data" = local.cloud_meta_data
  }

  shutdown_command = "sudo shutdown -P now"
}

build {
  name    = "rhel10-nginx-qcow2"
  sources = ["source.qemu.rhel10_nginx"]

  provisioner "shell" {
    script          = "${path.root}/../../scripts/provision-nginx.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "${path.root}/../../scripts/cleanup-image.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
