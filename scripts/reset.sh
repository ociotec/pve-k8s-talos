#!/usr/bin/env bash
set -euo pipefail

tofu destroy -auto-approve -refresh=false
./scripts/gen-talos-assets.sh
tofu apply -auto-approve

cp talosconfig ~/.talos/config
cp kubeconfig ~/.kube/config

kubectl get nodes
