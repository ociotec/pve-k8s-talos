# AGENTS.md

This file defines practical rules for AI/code agents working in this repository.
It complements `README.md` and focuses on execution behavior, change safety, and validation.

## Scope and Intent

- Treat this as an infrastructure repository for Talos + Kubernetes + Rook Ceph + monitoring on Proxmox VE.
- Prefer safe, incremental changes over broad refactors.
- Keep cluster-specific data under `clusters/<cluster>/` and reusable logic in top-level modules/scripts.

## Repository Mental Model

- Source modules live at repo root (`k8s-net/`, `monitoring/`, `rook/*`, root Talos OpenTofu files).
- Deployments run from generated cluster workspaces under `clusters/<cluster>/out/*`.
- `scripts/deploy.sh` and `scripts/gen-talos-assets.sh` build/link those workspaces and are the default operational path.
- Many files in `out/*` are symlinked from source; always update source files first, then verify generated workspaces.

## Required Working Style

- Run scripts from `clusters/<cluster>` (never from `clusters/sample`).
- Prefer `scripts/deploy.sh` for end-to-end deployment.
- Do not offer to run deployments on behalf of the user. When changes need to be applied, tell the user they must run the deployment themselves and provide the exact `scripts/deploy.sh` command with the minimum skip flags needed to deploy only the affected components and minimize runtime.
- Regenerate Talos assets whenever inputs change:
  - `constants.auto.tfvars`
  - `vms.auto.tfvars`
  - `resources.auto.tfvars`
  - `patches/machine.template.yaml`
- Keep skip flags consistent between generation and deployment (`--skip-ceph`, `--skip-k8s-net`, `--skip-platform`, `--skip-monitoring`).

## OpenTofu and Provider Rules

- Do not silently force provider upgrades in normal flows.
- Keep `required_providers` constraints compatible with committed `.terraform.lock.hcl` files.
- If constraints are increased, update lockfiles intentionally and verify init in affected workspaces.
- Validate at the same path where deployment runs (typically `clusters/<cluster>/out/...`), not only source modules.

## Change Placement Rules

- Prefer implementation layers in this order:
  - OpenTofu resources/modules first.
  - Direct API integrations second (Proxmox API, Talos API, Kubernetes API).
  - Kubernetes manifests third when no better typed resource exists.
  - SSH/remote command execution last, only when no safe declarative/API path is available.
- Put reusable logic in:
  - `scripts/*.sh` for orchestration and generation behavior
  - top-level module `main.tf` files for infrastructure definitions
- Put environment/cluster decisions in:
  - `clusters/<cluster>/*.tfvars`
  - `clusters/<cluster>/*_constants.tf`
- Avoid hardcoding cluster names, hostnames, paths, or secrets in shared modules.

## Certificates and TLS Conventions

- `k8s_net_constants.tf` is the source of truth for:
  - `tls_source`
  - `available_certificates`
  - `default_certificate_name`
- Consumers (monitoring, Portainer, Rook dashboard) should reference certificate catalog entries by name.
- In `preissued` mode, TLS secrets must be materialized from files, not from cert-manager `Certificate` resources.

## Ceph and Storage Conventions

- `ceph_constants.tf` owns Ceph mode (`internal`/`external`) and storage naming inputs.
- Monitoring storage class defaults must match Rook CSI naming conventions derived from `ceph_name_prefix`.
- When changing Rook CSI names or pool structure, verify monitoring constants still resolve valid StorageClass names.

## Kubernetes Manifest Provider Caveats

- `kubernetes_manifest` can drift on API-normalized fields (`{}` vs `null`, server-set annotations, etc.).
- Use `computed_fields`/`ignore_changes` for known unstable fields when provider inconsistencies are observed.
- Avoid unnecessary manifest churn; preserve field order and semantics unless a behavior change is intended.

## Kubernetes Resource Requirements

- Every service deployed into the cluster must define CPU and memory `requests` and `limits` for every container.
- This applies to Deployments, StatefulSets, DaemonSets, Jobs, CronJobs, init containers, and sidecars created by shared modules or manifests.
- Do not add or update a workload manifest without checking that all containers have both CPU and memory reservations and limits.
- For memory, set `requests.memory` equal to `limits.memory` to make OOM behavior explicit and avoid scheduling pods with lower memory reservations than their enforced ceiling.
- Write integer CPU quantities in Kubernetes-canonical core form instead of millicores to avoid provider/API normalization drift: use `"1"` instead of `"1000m"`, `"2"` instead of `"2000m"`, and so on. Keep fractional CPU quantities in millicores, such as `1500m` for 1.5 cores.
- Write whole-Gi memory quantities in Kubernetes-canonical Gi form for the same reason: use `"1Gi"` instead of `"1024Mi"`, `"2Gi"` instead of `"2048Mi"`, and so on. Keep non-whole values like `1536Mi` in Mi.
- `scripts/deploy.sh` has a preflight check that blocks integer CPU millicore values and whole-Gi memory values written as Mi in deployed modules for the same reason.

## Validation Checklist (Minimum)

For any non-trivial change:

1. Run `tofu init` in affected `out/*` workspace(s).
2. Run `tofu validate` in affected `out/*` workspace(s).
3. If change touches deployment orchestration, run the relevant `scripts/deploy.sh` path with appropriate skip flags.
4. If change touches asset generation, run `scripts/gen-talos-assets.sh --cluster <cluster>` and confirm outputs are produced.

## Safety Rules

- Never commit real secrets or private keys.
- Keep cert files under `clusters/<cluster>/certs/` and out of version control unless explicitly intended.
- Do not use real private URLs, private domains, internal hostnames, or private IPs in documentation, `clusters/sample`, shared modules, scripts, templates, or any other versioned repository content. Use reserved/example values instead (`example.com`, `example.net`, `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`). Real private endpoints are only allowed in ignored files under real cluster directories such as `clusters/<cluster>/`.
- Do not edit `clusters/sample` as if it were an active cluster runtime; use it as template/reference.
- Prefer additive, reversible edits; call out destructive implications explicitly.

## Console Output Policy

- Errors must always be shown in console output.
- Keep progress output minimal in normal mode.
- Emit detailed progress/debug logs only in verbose/debug mode.
- In deployment scripts, format user-facing URLs consistently with the existing URL style variables instead of printing raw URLs.

## Repo-Specific Agent Workflows

- When the user asks to audit or update pinned versions across the repository, follow `docs/agent-workflows/update-versions.md`.
- Treat files under `docs/agent-workflows/` as repo-local operating procedures for agents:
  - use them when the user request clearly matches the workflow
  - apply them together with this `AGENTS.md`, not instead of it
  - prefer them over any project-local `skills/` directory, since local skills are not auto-installed for users
- Keep workflow documents focused on reusable execution patterns, output shape, and decision rules.
- Keep repository safety and validation policy centralized in this `AGENTS.md`.

## Cluster Directory Hygiene

- Each real cluster must have its own dedicated directory under `clusters/<cluster>/`.
- Real cluster directories are local runtime data and should not be committed to Git.
- Keep per-cluster constants files as small as possible:
  - only cluster-specific values
  - no duplicated defaults that already exist in shared modules/templates
  - avoid embedding operational logic in constants files

## Suggested README Boundary

Information that belongs primarily here (agent behavior) rather than in `README.md`:

- Operational caveats about provider lock compatibility.
- Agent validation discipline in `out/*` workspaces.
- Provider inconsistency workarounds (`computed_fields`, `ignore_changes` strategy).
- Change placement policy (shared modules vs cluster constants).

`README.md` should remain user-facing setup/deploy documentation; `AGENTS.md` should remain implementation/maintenance guidance for contributors and agents.
