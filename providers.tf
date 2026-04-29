terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.99.0"
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
      version = ">= 2.6.1"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.5.0"
    }
  }
}
