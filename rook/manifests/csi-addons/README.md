# CSI-Addons manifests

These files are generated from the Kubernetes CSI-Addons `v0.14.0` release
manifests. Refresh and verify them with:

```bash
./scripts/update-csi-addons-manifests.sh
```

Repository ownership labels, priority, replica count, probes, and resource
requirements are applied declaratively by the Rook operator workspace. The
generator normalizes integer CPU quantities to Kubernetes canonical form.
