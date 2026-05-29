# Sample Infra VM

Copy this directory to `infra-vms/<name>` and update the constants before deploying.

```bash
cp -R infra-vms/sample infra-vms/bootstrap-example
cd infra-vms/bootstrap-example
cp envrc.sample .envrc
# edit .envrc and constants before running
direnv exec . ../../scripts/deploy-infra-vm.sh --plan
direnv exec . ../../scripts/deploy-infra-vm.sh
```

The VM is intended for bootstrap services that must exist before a Talos cluster starts, such as a private Talos discovery service or, later, a registry mirror.

Use a Debian cloud image already uploaded to Proxmox as `vm.cloud_image_file_id` or `vm.cloud_image_import_from`; a normal Debian installer ISO is not enough for unattended cloud-init provisioning.

Set `os.user_uid` and `os.user_gid` when the provisioned SSH user must keep fixed numeric IDs across rebuilds.
