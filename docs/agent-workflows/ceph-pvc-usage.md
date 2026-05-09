# Ceph PVC Usage Workflow

Use this workflow when the user wants to know which Kubernetes PVCs are consuming Ceph data pools for a repository cluster.

This workflow is repo-local guidance for agents. It is not a globally installed Codex skill.

## Required Input

The cluster name is required because kubeconfigs, constants, generated workspaces, and external Ceph connection details are cluster-specific.

If the user does not provide a cluster name, ask for it before running commands.

## Scope

Report PVC usage for Ceph data pools owned by the selected cluster.

Include:

- RBD data pools referenced by PV CSI attributes, such as `dataPool`.
- RBD replicated pools referenced directly by PV CSI `pool`, when they contain data.
- CephFS data pools referenced by PV CSI attributes or by the corresponding StorageClass, when they contain data.
- Only pools with non-zero data usage.

Exclude:

- Metadata, journal, monitor, manager, RGW, and other non-data pools.
- Pools with no objects and zero usage.
- RBD image names from the final table unless the user explicitly asks for them.

## Required Behavior

- Keep the answer minimal.
- Show one table per data pool.
- Put the summary at the end of each table with bold total rows.
- Include both logical PVC usage and raw Ceph pool usage:
  - `PVC total`: sum of per-PVC provisioned and used values.
  - `Ceph raw total`: Ceph pool raw usage from `ceph df`; leave `Provisioned` empty because raw pool usage is not a PVC request sum.
- Do not add a separate prose summary when the table already contains the totals.
- Use the user's language unless they ask for another language.
- If a pool name from the user appears to have a typo, state the effective pool name briefly before the table.
- If `rbd du` warns that `fast-diff` is not enabled, continue and do not include the warnings in the final answer unless they affect completion.

## Output Format

For each pool, render the pool name as a Markdown level-3 header. Put pool metadata immediately below it as a short bullet list:

```md
### <pool>
* Storage class: <storage-class>
* EC: k (<k>) + m (<m>)
```

For replicated pools, use:

```md
### <pool>
* Storage class: <storage-class>
* Replicated: <size>
```

Use this column set unless the user requests a different shape:

| Namespace | PVC | Provisioned | Used | % Used |

The final rows must be:

| **PVC total** |  | **`<sum provisioned>`** | **`<sum used>`** | **`<sum used / sum provisioned>`** |
| **Ceph raw total** |  |  | **`<pool raw used>`** |  |

If a single data pool has multiple StorageClasses, use:

`### <pool>`

then list all StorageClasses in the metadata bullet:

```md
* Storage class: <storage-class-1>, <storage-class-2>
```

and add a `StorageClass` column to that pool's table only.

Sort rows by `Used` descending when per-volume usage is available.

## Workflow

1. Identify the cluster directory:
   - `clusters/<cluster>/`
   - kubeconfig: `clusters/<cluster>/out/kubeconfig`
   - Ceph constants: `clusters/<cluster>/ceph_constants.tf`
2. Read `ceph_constants.tf` to confirm:
   - `ceph_mode`
   - `ceph_name_prefix`
   - block and filesystem pool shape, such as EC `k`/`m` or replicated `size`
   - external Ceph SSH host, when `ceph_mode = "external"`
3. Query Kubernetes PVs:
   - `kubectl --kubeconfig clusters/<cluster>/out/kubeconfig get pv -o json`
4. From each bound CSI PV, collect:
   - namespace: `.spec.claimRef.namespace`
   - PVC: `.spec.claimRef.name`
   - StorageClass: `.spec.storageClassName`
   - provisioned size: `.spec.capacity.storage`
   - RBD image name: `.spec.csi.volumeAttributes.imageName`
   - data pool:
     - use `.spec.csi.volumeAttributes.dataPool` for erasure-coded RBD
     - otherwise use `.spec.csi.volumeAttributes.pool` only when it is not a metadata or journal pool
5. Query Ceph pool usage:
   - `ceph df detail --format json`
   - for external Ceph, run it via SSH on the configured external Ceph host.
6. Keep only data pools that:
   - are referenced by the selected cluster PVs or StorageClasses
   - do not look like metadata/journal pools
   - have non-zero stored, raw used, or object count in `ceph df`
7. For RBD pools, query per-image usage:
   - EC RBD: run `rbd du -p <metadata-pool> --format json`, because CSI images are listed in the metadata pool while their data is stored in `dataPool`.
   - Replicated RBD: run `rbd du -p <data-pool> --format json`.
8. Join `rbd du` image usage back to PVs by CSI `imageName`.
9. Group rows by data pool.
10. Build one output table per data pool without pool or image name columns.
11. If every row in a pool has the same StorageClass, put it in the metadata bullet list and omit the `StorageClass` column.
12. Add a metadata bullet under the pool header for pool type:
   - EC pools: `* EC: k (<k>) + m (<m>)`
   - replicated pools: `* Replicated: <size>`
13. Add `% Used` as `Used / Provisioned` for each PVC when per-volume usage is available.
14. Add the final `PVC total` row to each pool table, with every non-empty cell in bold.
15. Add the final `Ceph raw total` row to each pool table, with every non-empty cell in bold.

## Size Rules

- Preserve Kubernetes provisioned sizes in human-friendly units, typically `Gi`.
- Render used bytes in compact binary units, typically `MiB` or `GiB`.
- Sum totals from raw byte values, then render the total once.
- Prefer per-image `rbd du` `used_size` for the `Used` column when available.
- Render `% Used` with one decimal place unless it is below `0.1%`; then use `<0.1%`.
- If per-volume usage is unavailable for a pool, leave per-PVC `Used` and `% Used` empty and put the pool-level `ceph df` usage in the `Ceph raw total` row only, with a brief note.

## CephFS Notes

CephFS per-PVC usage may require subvolume inspection rather than `rbd du`.

If CephFS PVCs are present:

- identify the filesystem and data pool from the PV or StorageClass
- use Ceph subvolume commands when available to map the PVC volume handle to usage
- otherwise report provisioned size per PVC and pool-level used total only

Do not block the RBD report on incomplete CephFS per-PVC attribution.

## How To Invoke

Typical user requests that should trigger this workflow:

- `Show Ceph PVC usage for cluster eht`
- `Which PVCs are using the external Ceph data pool?`
- `Where is the talos-rbd-ec-data pool being spent?`
- `Audit PVC usage by Ceph pool for <cluster>`
