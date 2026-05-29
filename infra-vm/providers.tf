terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.104.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.8.0"
    }
  }
}

provider "proxmox" {
}

provider "local" {
}
