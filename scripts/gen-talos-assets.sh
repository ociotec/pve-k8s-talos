#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_path="${repo_root}/patches/machine.template.yaml"
hostname_template_path="${repo_root}/patches/hostname.template.yaml"
qemu_template_path="${repo_root}/patches/qemu.template.yaml"
vms_path="${repo_root}/vms_list.tf"
constants_path="${repo_root}/vms_constants.tf"
resources_path="${repo_root}/vms_resources.tf"
patch_dir="${repo_root}/patches"
talos_tf_path="${repo_root}/talos.tf"
talos_template_path="${repo_root}/templates/talos.template.tf"
controlplane_data_template_path="${repo_root}/templates/controlplane-data.template.tf"
worker_data_template_path="${repo_root}/templates/worker-data.template.tf"
machine_config_locals_template_path="${repo_root}/templates/machine-config-locals.template.tf"
talos_dir="$(dirname "${talos_tf_path}")"

if ! command -v awk >/dev/null 2>&1; then
  echo "Error: 'awk' is required but not found in PATH. Install awk or fix PATH." >&2
  exit 1
fi

if [[ ! -r "${template_path}" ]]; then
  echo "Error: template not readable: ${template_path}" >&2
  echo "Fix: ensure the file exists and is readable (git checkout or restore it)." >&2
  exit 1
fi

if [[ ! -r "${hostname_template_path}" ]]; then
  echo "Error: hostname template not readable: ${hostname_template_path}" >&2
  echo "Fix: ensure patches/hostname.template.yaml exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${qemu_template_path}" ]]; then
  echo "Error: qemu template not readable: ${qemu_template_path}" >&2
  echo "Fix: ensure patches/qemu.template.yaml exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${vms_path}" ]]; then
  echo "Error: VM list not readable: ${vms_path}" >&2
  echo "Fix: ensure vms_list.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${constants_path}" ]]; then
  echo "Error: constants file not readable: ${constants_path}" >&2
  echo "Fix: ensure vms_constants.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${resources_path}" ]]; then
  echo "Error: resources file not readable: ${resources_path}" >&2
  echo "Fix: ensure vms_resources.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -d "${patch_dir}" ]]; then
  echo "Error: patches directory not found: ${patch_dir}" >&2
  echo "Fix: create the directory (mkdir -p patches) or restore it from git." >&2
  exit 1
fi

if [[ -e "${talos_tf_path}" && ! -w "${talos_tf_path}" ]]; then
  echo "Error: talos.tf is not writable: ${talos_tf_path}" >&2
  echo "Fix: adjust permissions or remove the read-only file before regenerating." >&2
  exit 1
fi

if [[ ! -e "${talos_tf_path}" && ! -w "${talos_dir}" ]]; then
  echo "Error: talos.tf cannot be created in: ${talos_dir}" >&2
  echo "Fix: ensure the directory is writable." >&2
  exit 1
fi

if [[ ! -r "${talos_template_path}" ]]; then
  echo "Error: talos.tf template not readable: ${talos_template_path}" >&2
  echo "Fix: ensure templates/talos.template.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${controlplane_data_template_path}" ]]; then
  echo "Error: controlplane data template not readable: ${controlplane_data_template_path}" >&2
  echo "Fix: ensure templates/controlplane-data.template.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${worker_data_template_path}" ]]; then
  echo "Error: worker data template not readable: ${worker_data_template_path}" >&2
  echo "Fix: ensure templates/worker-data.template.tf exists and is readable." >&2
  exit 1
fi

if [[ ! -r "${machine_config_locals_template_path}" ]]; then
  echo "Error: machine config locals template not readable: ${machine_config_locals_template_path}" >&2
  echo "Fix: ensure templates/machine-config-locals.template.tf exists and is readable." >&2
  exit 1
fi

# Read network constants from vms_constants.tf.
net_size="$(awk -F'"' '/"net_size"/ { print $4; exit }' "${constants_path}")"
gateway="$(awk -F'"' '/"gateway"/ { print $4; exit }' "${constants_path}")"
dns_servers="$(awk -F'"' '/"dns_servers"/ { print $4; exit }' "${constants_path}")"
ntp_servers="$(awk -F'"' '/"ntp_servers"/ { print $4; exit }' "${constants_path}")"
talos_version="$(awk -F'"' '/"version"/ { print $4; exit }' "${constants_path}")"
talos_factory_image_id="$(awk -F'"' '/"factory_image_id"/ { print $4; exit }' "${constants_path}")"
disk_by_id_prefix="$(awk -F'"' '/"disk_by_id_prefix"/ { print $4; exit }' "${constants_path}")"

if [[ -z "${net_size}" || -z "${gateway}" || -z "${dns_servers}" ]]; then
  echo "Error: missing network constants in vms_constants.tf." >&2
  echo "Fix: ensure net_size, gateway, dns_servers exist under var.constants[\"network\"]." >&2
  exit 1
fi

if [[ -z "${talos_version}" || -z "${talos_factory_image_id}" ]]; then
  echo "Error: missing Talos constants in vms_constants.tf." >&2
  echo "Fix: ensure version and factory_image_id exist under var.constants[\"talos\"]." >&2
  exit 1
fi

if [[ -z "${disk_by_id_prefix}" ]]; then
  echo "Error: missing disk_by_id_prefix in vms_constants.tf." >&2
  echo "Fix: set vm.disk_by_id_prefix to match /dev/disk/by-id prefix (for example scsi-0QEMU_QEMU_HARDDISK_drive-scsi)." >&2
  exit 1
fi
# Load the machine patch template.
template="$(cat "${template_path}")"

# Basic template sanity check.
if [[ "${template}" != *'${ip}'* || "${template}" != *'${cidr}'* || "${template}" != *'${machine_disks_section}'* ]]; then
  echo "Error: template is missing required placeholders (\${ip}, \${cidr}, \${machine_disks_section})." >&2
  echo "Fix: restore patches/machine.template.yaml or add the missing placeholders." >&2
  exit 1
fi

hostname_template="$(cat "${hostname_template_path}")"
if [[ "${hostname_template}" != *'${hostname}'* ]]; then
  echo "Error: hostname template is missing required placeholder (\${hostname})." >&2
  echo "Fix: restore patches/hostname.template.yaml or add the missing placeholder." >&2
  exit 1
fi

dns_servers_section=""
IFS=',' read -ra dns_list <<< "${dns_servers}"
for server in "${dns_list[@]}"; do
  server="${server#"${server%%[![:space:]]*}"}"
  server="${server%"${server##*[![:space:]]}"}"
  if [[ -n "${server}" ]]; then
    if [[ -n "${dns_servers_section}" ]]; then
      dns_servers_section+=", "
    fi
    dns_servers_section+="${server}"
  fi
done
if [[ -z "${dns_servers_section}" ]]; then
  echo "Error: dns_servers must contain at least one entry." >&2
  exit 1
fi

ntp_servers_section=""
if [[ -n "${ntp_servers}" ]]; then
  IFS=',' read -ra ntp_list <<< "${ntp_servers}"
  for server in "${ntp_list[@]}"; do
    server="${server#"${server%%[![:space:]]*}"}"
    server="${server%"${server##*[![:space:]]}"}"
    if [[ -n "${server}" ]]; then
      if [[ -n "${ntp_servers_section}" ]]; then
        ntp_servers_section+=", "
      fi
      ntp_servers_section+="${server}"
    fi
  done
fi

qemu_template="$(cat "${qemu_template_path}")"
if [[ "${qemu_template}" != *'${talos_version}'* || "${qemu_template}" != *'${talos_factory_image_id}'* ]]; then
  echo "Error: qemu template is missing required placeholders (\${talos_version}, \${talos_factory_image_id})." >&2
  echo "Fix: restore patches/qemu.template.yaml or add the missing placeholders." >&2
  exit 1
fi

qemu_rendered="${qemu_template}"
qemu_rendered="${qemu_rendered//'${talos_version}'/${talos_version}}"
qemu_rendered="${qemu_rendered//'${talos_factory_image_id}'/${talos_factory_image_id}}"
qemu_out_path="${patch_dir}/qemu.yaml"
printf "%s\n" "${qemu_rendered}" > "${qemu_out_path}"
echo "wrote ${qemu_out_path}"

# Parse vms_list.tf for vm names and IPs, ignoring commented lines.
declare -A vm_ips
while IFS='|' read -r name ip; do
  if [[ -z "${name}" || -z "${ip}" ]]; then
    continue
  fi
  vm_ips["${name}"]="${ip}"
done < <(
  awk '
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*/, "", name)
      in_block = 1
      next
    }
    in_block && match($0, /ip[[:space:]]*=[[:space:]]*"[^"]+"/) {
      ip = $0
      sub(/^[^"]*"/, "", ip)
      sub(/".*/, "", ip)
      print name "|" ip
      in_block = 0
      next
    }
    in_block && /}/ { in_block = 0 }
  ' "${vms_path}"
)

if [[ ${#vm_ips[@]} -eq 0 ]]; then
  echo "Error: no VMs found in vms_list.tf." >&2
  echo "Fix: add VM entries or remove commented-only entries." >&2
  exit 1
fi

# Build VM role lists from vms_list.tf.
declare -A vm_types
controlplane_names=()
worker_names=()
while IFS='|' read -r name role; do
  if [[ -z "${name}" || -z "${role}" ]]; then
    continue
  fi
  vm_types["${name}"]="${role}"
  if [[ "${role}" == "controlplane" ]]; then
    controlplane_names+=("${name}")
  elif [[ "${role}" == "worker" ]]; then
    worker_names+=("${name}")
  fi
done < <(
  awk '
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*/, "", name)
      in_block = 1
      next
    }
    in_block && match($0, /type[[:space:]]*=[[:space:]]*"[^"]+"/) {
      role = $0
      sub(/^[^"]*"/, "", role)
      sub(/".*/, "", role)
      print name "|" role
      in_block = 0
      next
    }
    in_block && /}/ { in_block = 0 }
  ' "${vms_path}"
)

if [[ ${#controlplane_names[@]} -eq 0 || ${#worker_names[@]} -eq 0 ]]; then
  echo "Error: could not detect controlplane/worker VM types in vms_list.tf." >&2
  echo "Fix: ensure each VM block has type = \"controlplane\" or type = \"worker\"." >&2
  exit 1
fi

for name in "${!vm_ips[@]}"; do
  if [[ -z "${vm_types[${name}]:-}" ]]; then
    echo "Error: VM ${name} has no type in vms_list.tf." >&2
    echo "Fix: add type = \"controlplane\" or type = \"worker\" for ${name}." >&2
    exit 1
  fi
done

declare -A disk_mounts
declare -A disk_counts
while IFS='|' read -r vm_type size mount; do
  count="${disk_counts[${vm_type}]:-0}"
  if [[ -n "${mount}" ]]; then
    disk_mounts["${vm_type}|${count}"]="${mount}"
  fi
  disk_counts["${vm_type}"]=$((count + 1))
done < <(
  awk '
    /^[[:space:]]*#/ { next }
    match($0, /"[^"]+"[[:space:]]*=[[:space:]]*{/) {
      current = $0
      sub(/^[^"]*"/, "", current)
      sub(/".*/, "", current)
      in_block = 1
      next
    }
    in_block && match($0, /disks[[:space:]]*=/) { in_disks = 1 }
    in_block && in_disks {
      line = $0
      gsub(/#.*/, "", line)
      if (line ~ /]/) { in_disks = 0 }
      if (line ~ /size[[:space:]]*=/) {
        gsub(/[{}]/, "", line)
        size = ""
        mount = ""
        n = split(line, parts, ",")
        for (i = 1; i <= n; i++) {
          part = parts[i]
          gsub(/^[[:space:]]+/, "", part)
          gsub(/[[:space:]]+$/, "", part)
          if (part ~ /^size[[:space:]]*=/) {
            sub(/^size[[:space:]]*=/, "", part)
            gsub(/[[:space:]]*/, "", part)
            size = part
          }
          if (part ~ /^mount[[:space:]]*=/) {
            sub(/^mount[[:space:]]*=/, "", part)
            gsub(/^[[:space:]]*"/, "", part)
            gsub(/"[[:space:]]*$/, "", part)
            mount = part
          }
        }
        if (size != "") {
          print current "|" size "|" mount
        }
      }
      next
    }
    in_block && /}/ { in_block = 0 }
  ' "${resources_path}"
)

# Render per-VM machine patch files from the template.
for name in "${!vm_ips[@]}"; do
  ip="${vm_ips[${name}]}"
  if [[ ! "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "Error: invalid IP format for ${name}: ${ip}" >&2
    echo "Fix: set a valid IPv4 address in vms_list.tf for ${name}." >&2
    exit 1
  fi
  vm_type="${vm_types[${name}]}"
  disks_block=""
  disk_total="${disk_counts[${vm_type}]:-0}"
  for ((idx=0; idx<disk_total; idx++)); do
    mount_path="${disk_mounts[${vm_type}|${idx}]:-}"
    if [[ -z "${mount_path}" ]]; then
      continue
    fi
    if [[ "${mount_path}" != /var/* ]]; then
      echo "Error: mount path must be under /var for ${vm_type} disk index ${idx} (got ${mount_path})." >&2
      echo "Fix: use a /var-based mountpoint like /var/mnt/... or /var/lib/...." >&2
      exit 1
    fi
    device="/dev/disk/by-id/${disk_by_id_prefix}${idx}"
    disks_block+=$'\n    - device: '"${device}"$'\n      partitions:\n        - mountpoint: '"${mount_path}"$'\n          size: 0 # Use full disk'
  done
  if [[ -n "${disks_block}" ]]; then
    machine_disks_section="${disks_block}"
  else
    machine_disks_section=" []"
  fi

  rendered="${template}"
  rendered="${rendered//'${ip}'/${ip}}"
  rendered="${rendered//'${cidr}'/${net_size}}"
  rendered="${rendered//'${gateway}'/${gateway}}"
  rendered="${rendered//'${dns_servers_section}'/${dns_servers_section}}"
  rendered="${rendered//'${ntp_servers_section}'/${ntp_servers_section}}"
  rendered="${rendered//'${machine_disks_section}'/${machine_disks_section}}"
  out_path="${patch_dir}/machine-${name}.yaml"
  printf "%s\n" "${rendered}" > "${out_path}"
  echo "wrote ${out_path}"

  hostname_rendered="${hostname_template//'${hostname}'/${name}}"
  hostname_out_path="${patch_dir}/hostname-${name}.yaml"
  printf "%s\n" "${hostname_rendered}" > "${hostname_out_path}"
  echo "wrote ${hostname_out_path}"
done

# Remove stale patch files not present in vms_list.tf.
for path in "${patch_dir}"/machine-*.yaml; do
  [[ -e "${path}" ]] || continue
  base="$(basename "${path}")"
  name="${base#machine-}"
  name="${name%.yaml}"
  if [[ -z "${vm_ips[${name}]:-}" ]]; then
    rm -f "${path}"
    echo "removed ${path}"
  fi
done

for path in "${patch_dir}"/network-*.yaml; do
  [[ -e "${path}" ]] || continue
  rm -f "${path}"
  echo "removed ${path}"
done

for path in "${patch_dir}"/hostname-*.yaml; do
  [[ -e "${path}" ]] || continue
  base="$(basename "${path}")"
  name="${base#hostname-}"
  name="${name%.yaml}"
  if [[ -z "${vm_ips[${name}]:-}" ]]; then
    rm -f "${path}"
    echo "removed ${path}"
  fi
done

primary_controlplane="${controlplane_names[0]}"
if [[ -z "${primary_controlplane}" ]]; then
  echo "Error: unable to determine primary control plane VM." >&2
  echo "Fix: ensure vms_list.tf contains at least one controlplane entry." >&2
  exit 1
fi

controlplane_data_template="$(cat "${controlplane_data_template_path}")"
worker_data_template="$(cat "${worker_data_template_path}")"
machine_config_locals_template="$(cat "${machine_config_locals_template_path}")"

if [[ "${controlplane_data_template}" != *"__SAFE_NAME__"* || \
      "${controlplane_data_template}" != *"__NAME__"* || \
      "${controlplane_data_template}" != *"__PRIMARY_CONTROLPLANE__"* ]]; then
  echo "Error: controlplane data template is missing required placeholders." >&2
  echo "Fix: add __SAFE_NAME__, __NAME__, and __PRIMARY_CONTROLPLANE__ to templates/controlplane-data.template.tf." >&2
  exit 1
fi

if [[ "${worker_data_template}" != *"__SAFE_NAME__"* || \
      "${worker_data_template}" != *"__NAME__"* || \
      "${worker_data_template}" != *"__PRIMARY_CONTROLPLANE__"* ]]; then
  echo "Error: worker data template is missing required placeholders." >&2
  echo "Fix: add __SAFE_NAME__, __NAME__, and __PRIMARY_CONTROLPLANE__ to templates/worker-data.template.tf." >&2
  exit 1
fi

if [[ "${machine_config_locals_template}" != *"__CONTROLPLANE_LOCALS__"* || \
      "${machine_config_locals_template}" != *"__WORKER_LOCALS__"* ]]; then
  echo "Error: machine config locals template is missing required placeholders." >&2
  echo "Fix: add __CONTROLPLANE_LOCALS__ and __WORKER_LOCALS__ to templates/machine-config-locals.template.tf." >&2
  exit 1
fi

controlplane_blocks=()
for name in "${controlplane_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  block="${controlplane_data_template}"
  block="${block//__SAFE_NAME__/${safe_name}}"
  block="${block//__NAME__/${name}}"
  block="${block//__PRIMARY_CONTROLPLANE__/${primary_controlplane}}"
  block="${block%$'\n'}"
  controlplane_blocks+=("${block}")
done
controlplane_data="$(printf "%s\n\n" "${controlplane_blocks[@]}")"
controlplane_data="${controlplane_data%$'\n\n'}"
controlplane_data+=$'\n'

worker_blocks=()
for name in "${worker_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  block="${worker_data_template}"
  block="${block//__SAFE_NAME__/${safe_name}}"
  block="${block//__NAME__/${name}}"
  block="${block//__PRIMARY_CONTROLPLANE__/${primary_controlplane}}"
  block="${block%$'\n'}"
  worker_blocks+=("${block}")
done
worker_data="$(printf "%s\n\n" "${worker_blocks[@]}")"
worker_data="${worker_data%$'\n\n'}"
worker_data+=$'\n'

controlplane_locals=""
for name in "${controlplane_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  controlplane_locals+="    \"${name}\" = format(\"%s\\n---\\n%s\\n\", trimspace(join(\"\\\\n---\\\\n\", [for doc in split(\"\\\\n---\\\\n\", data.talos_machine_configuration.machineconfig_${safe_name}.machine_configuration) : doc if !startswith(doc, \"apiVersion: v1alpha1\\\\nkind: HostnameConfig\\\\n\")])), trimspace(file(\"\${path.module}/patches/hostname-${name}.yaml\")))"$'\n'
done

worker_locals=""
for name in "${worker_names[@]}"; do
  safe_name="${name//[^a-zA-Z0-9_]/_}"
  worker_locals+="    \"${name}\" = format(\"%s\\n---\\n%s\\n\", trimspace(join(\"\\\\n---\\\\n\", [for doc in split(\"\\\\n---\\\\n\", data.talos_machine_configuration.machineconfig_${safe_name}.machine_configuration) : doc if !startswith(doc, \"apiVersion: v1alpha1\\\\nkind: HostnameConfig\\\\n\")])), trimspace(file(\"\${path.module}/patches/hostname-${name}.yaml\")))"$'\n'
done

controlplane_locals="${controlplane_locals%$'\n'}"
worker_locals="${worker_locals%$'\n'}"
locals_block="${machine_config_locals_template}"
locals_block="${locals_block//__CONTROLPLANE_LOCALS__/${controlplane_locals}}"
locals_block="${locals_block//__WORKER_LOCALS__/${worker_locals}}"
locals_block="${locals_block%$'\n'}"
locals_block+=$'\n'

talos_template="$(cat "${talos_template_path}")"
if [[ "${talos_template}" != *"__CONTROLPLANE_DATA__"* || \
      "${talos_template}" != *"__WORKER_DATA__"* || \
      "${talos_template}" != *"__MACHINE_CONFIG_LOCALS__"* || \
      "${talos_template}" != *"__CONTROLPLANE_PRIMARY__"* ]]; then
  echo "Error: talos.tf template is missing required placeholders." >&2
  echo "Fix: ensure templates/talos.template.tf contains __CONTROLPLANE_PRIMARY__, __CONTROLPLANE_DATA__, __WORKER_DATA__, and __MACHINE_CONFIG_LOCALS__." >&2
  exit 1
fi

talos_rendered="${talos_template//__CONTROLPLANE_PRIMARY__/${primary_controlplane}}"
talos_rendered="${talos_rendered//__CONTROLPLANE_DATA__/${controlplane_data}}"
talos_rendered="${talos_rendered//__WORKER_DATA__/${worker_data}}"
talos_rendered="${talos_rendered//__MACHINE_CONFIG_LOCALS__/${locals_block}}"
talos_rendered="$(printf "%s" "${talos_rendered}" | awk '
  BEGIN { blank = 0 }
  /^$/ {
    blank++
    if (blank == 1) { print }
    next
  }
  { blank = 0; print }
')"

printf "%s" "${talos_rendered}" > "${talos_tf_path}"
echo "generated ${talos_tf_path}"
