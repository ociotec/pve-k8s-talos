# Cluster Deployment Status

Each real cluster can store the last known repository revisions applied to each
deployment section in Kubernetes:

- namespace: `kube-system`
- ConfigMap: `pve-k8s-talos-deployment-status`

This cluster-side record is the shared source of deployment provenance for all
PCs and repository clones. The local `clusters/<cluster>/.repo-status.json`
file is deprecated and must not be used as evidence of live deployment state.

## Repository Sources

Every real cluster is expected to be an independent Git repository nested at
`clusters/<cluster>`. Deployment status references two repositories:

- `platform`: this `pve-k8s-talos` repository
- `cluster`: the real cluster repository

Their canonical, credential-free origin URLs are stored once in
`repositories.json`. Each deployment section stores the commit and dirty state
used from both repositories.

After a successful deployment, `runtime-state.json` stores the cluster
repository commit containing the resulting OpenTofu state and runtime files.
This is intentionally separate from the cluster source revision captured at
deployment start.

The `platform` and `cluster` aliases are stable identities. A repository URL may
move while preserving the same Git history, but an alias must not be rebound to
an unrelated repository history without an explicit schema migration.

Do not persist remote URLs containing credentials, tokens, query strings, or
fragments. `scripts/deployment-status.sh` sanitizes the common HTTPS and SSH
remote formats before writing them.

## Canonical Sections

- `k8s`: PVE VMs, Talos configuration, Kubernetes bootstrap, and node
  convergence from `out/root`
- `k8s-net`
- `ceph`
- `identity`
- `s3`
- `monitoring`
- `platform`
- `kafka`
- `benchmark`

Sections that have never been deployed are absent from the ConfigMap. Skipped
sections keep their previous status when one exists. `--services-only` never
updates `k8s`.

The Rook dashboard is a dependent Rook integration applied later in
`scripts/deploy.sh`; the `ceph` revision is advanced after the main Rook Ceph
section has completed successfully.

## Status Semantics

An entry written by `scripts/deploy.sh` has:

- `provenance = "deploy.sh"`
- `deployed_at`: the UTC time at which the section completed
- `deployment_id`: one identifier shared by every section completed during the
  same `deploy.sh` invocation
- `revisions.platform` and `revisions.cluster`

`deployment_id` correlates sections from one deployment run. It is not a Git
commit or Kubernetes object UID.

The revisions and dirty flags are captured before `deploy.sh` starts changing
generated workspaces or tracked state files. If either source worktree is dirty
at that point, its revision records `dirty = true`. A dirty revision identifies
the base commit but is not exactly reproducible from another clone.

Mandatory state synchronization means deployment starts only from clean
repositories, so both dirty flags are false. The later runtime-state commit is
a derived deployment result and does not change the source revision used by
each section.

An initial adoption entry has:

- `provenance = "operator-confirmed-baseline"`
- `recorded_at`: when the assertion was recorded
- `deployed_at = null`

A baseline records an explicit operator assertion that the selected sections
already match the supplied revisions. It does not invent or infer a historical
deployment time.

## Commands

Run commands from the real cluster directory with its environment loaded:

```bash
cd clusters/<cluster>
direnv exec . ../../scripts/deployment-status.sh show
```

If the local `.envrc` is intentionally not approved by direnv:

```bash
cd clusters/<cluster>
bash -lc 'source .envrc; ../../scripts/deployment-status.sh show'
```

Create a baseline only after the operator explicitly confirms both the cluster
and the exact section list are aligned:

```bash
../../scripts/deployment-status.sh baseline \
  --sections k8s,k8s-net,ceph,identity,s3,monitoring,platform,kafka,benchmark \
  --confirm-aligned
```

When the worktrees no longer point at the confirmed deployment revisions, pass
both known commits explicitly:

```bash
../../scripts/deployment-status.sh baseline \
  --sections k8s,k8s-net,ceph,identity,s3,monitoring,platform,kafka,benchmark \
  --confirm-aligned \
  --platform-commit <platform-commit> \
  --cluster-commit <cluster-commit>
```

Always inspect the actual section set before creating a baseline. Do not add a
section merely because its constants file or generated workspace exists.

## Failure and Availability

Writing deployment status is part of successful section completion. A write
failure is shown as an error and the deployment command exits non-zero rather
than silently claiming that provenance was recorded.

The ConfigMap is unavailable while the Kubernetes API is unavailable and is
removed with a fully destroyed cluster. In those cases, report live deployment
status as unknown. Do not fall back to a local stamp as authoritative evidence.

The ConfigMap records provenance but does not replace OpenTofu state or provide
deployment locking. When a private cluster repository versions runtime state,
it must include `out/**/terraform.tfstate`, `out/kubeconfig`,
`out/talosconfig`, and `out/.talos-bootstrap-complete`. The last file is a
stable Talos lifecycle marker, not a deployment-revision stamp; omitting it
causes the root workspace to treat an existing cluster as not yet bootstrapped.
Operators must still run deployments from one PC at a time.

State synchronization is a mandatory part of every `scripts/deploy.sh` run:

1. Require clean platform and cluster repositories.
2. Fetch and require the platform branch to match its upstream.
3. Pull the cluster branch with `git pull --ff-only` and push any clean local
   commits that were not yet published.
4. Run the deployment from the captured clean source revisions.
5. Commit and push only the allowlisted runtime files after success.
6. On failure, commit and push any partial runtime-state changes without
   advancing the failed section's deployment record.
7. After success, record the resulting runtime-state commit in the ConfigMap.

Unexpected source or configuration changes block the automatic commit. If the
push fails, the local state commit is preserved and the command exits non-zero;
do not use another PC until that commit has been pushed. This behavior cannot
be disabled for a `deploy.sh` run.

A successful `--destroy-only` commits and pushes the removal of all tracked
runtime files. Because the Kubernetes API no longer exists, no ConfigMap update
is attempted. A later normal deployment sees no state or bootstrap marker and
performs a fresh cluster bootstrap. Failed or partial destruction preserves
and pushes the remaining authoritative state instead.

Do not version `terraform.tfstate.backup`, `.terraform/`, or
`.terraform.tfstate.lock.info`. Git history already provides previous committed
state versions.

When comparing a recorded cluster revision with the repository `HEAD`, changes
limited to `out/**/terraform.tfstate`, `out/kubeconfig`, `out/talosconfig`, or
`out/.talos-bootstrap-complete` are runtime-state drift, not evidence that a
deployment section is stale.
