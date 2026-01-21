terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.93.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.10.1"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.6.1"
    }
  }
}
