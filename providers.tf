terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.104.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.10.1, < 0.11.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.8.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.5.0"
    }
  }
}
