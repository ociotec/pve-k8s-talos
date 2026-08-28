#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
version="v0.14.0"
release_url="https://github.com/csi-addons/kubernetes-csi-addons/releases/download/${version}"
destination="${repo_root}/rook/manifests/csi-addons"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

curl -fsSL "${release_url}/crds.yaml" -o "${work_dir}/crds.yaml"
curl -fsSL "${release_url}/rbac.yaml" -o "${work_dir}/rbac.yaml"
curl -fsSL "${release_url}/setup-controller.yaml" -o "${work_dir}/setup-controller.yaml"

(
  cd "${work_dir}"
  sha256sum -c <<'CHECKSUMS'
6d2d97ba0925657f8b9e3c1810da9be5d420e30052aef62e40ba20b1c00f15b2  crds.yaml
87286263fa7ae4c9cafebca480e62bf5bb92c4aed58a71ccab6926988ec559f5  rbac.yaml
db00008852c8ae08b1bd6ca1bb7ee89620fd747e68f4b5ca5a316c1f86c93020  setup-controller.yaml
CHECKSUMS
)

mkdir -p "${destination}"
install -m 0644 "${work_dir}/crds.yaml" "${destination}/crds.yaml"
install -m 0644 "${work_dir}/rbac.yaml" "${destination}/rbac.yaml"
install -m 0644 "${work_dir}/setup-controller.yaml" "${destination}/setup-controller.yaml"
