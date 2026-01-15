terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.93.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.10.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.6.1"
    }
  }
}
