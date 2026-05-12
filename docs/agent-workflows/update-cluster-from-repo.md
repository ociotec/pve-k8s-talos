# Update Cluster From Repository Workflow

Use this workflow when the user wants to bring an existing real cluster directory
under `clusters/<cluster>/` up to date with the current repository layout,
especially after shared modules, scripts, templates, or sample constants changed.

This workflow is repo-local guidance for agents. It is not a globally installed
Codex skill.

## Scope

Handle cluster-local files such as:

- `constants.auto.tfvars`
- `vms.auto.tfvars`
- `resources.auto.tfvars`
- `k8s_net_constants.tf`
- `ceph_constants.tf`
- `identity_constants.tf`
- `platform_constants.tf`
- `monitoring_constants.tf`
- cluster-local supporting directories such as `certs/` and `patches/` only when
  they are referenced by cluster constants

Use `clusters/sample` as the authoritative template for the current repository
shape. Assume `clusters/sample` is aligned with the repository version being
worked on.

## Required Behavior

- Always require an explicit cluster name. If the user did not provide one, ask
  for it before editing.
- Never use `clusters/sample` as the runtime cluster and never edit it as if it
  were an active cluster.
- Preserve existing cluster values whenever possible.
- If the repository changed the structure that holds a value, move the existing
  value into the new structure instead of replacing it with the sample value.
- Do not copy environment-specific values from `clusters/sample` into a real
  cluster unless they are harmless defaults and still correct for that cluster.
- For every value the user must decide or fill in manually, add a nearby comment
  containing `TODO` so it is easy to locate later.
- At the end of the work, report every user-editable `TODO` location as a list
  of clickable file links with line numbers.
- Do not run deployments on behalf of the user. If deployment is needed, provide
  the exact `scripts/deploy.sh` command for the user to run from
  `clusters/<cluster>`, with the minimum skip flags needed for the affected
  components.
- Keep skip flags consistent between Talos asset generation and deployment.
- Do not expose or summarize secret values in the final answer.

## Workflow

1. Confirm the cluster name and verify `clusters/<cluster>/` exists and is not
   `clusters/sample`.
2. Inspect `git status --short` before editing. Do not overwrite unrelated user
   changes.
3. Compare the cluster directory with `clusters/sample`:
   - identify missing constants files
   - identify missing top-level locals in `*_constants.tf`
   - identify missing top-level maps and nested keys in `*.auto.tfvars`
   - identify keys that moved or were renamed by comparing nearby semantics and
     current module usage
4. Inspect current repository consumers, not only `clusters/sample`:
   - `scripts/common.sh`
   - `scripts/deploy.sh`
   - `scripts/gen-talos-assets.sh`
   - root OpenTofu files and templates
   - component modules under `k8s-net/`, `rook/`, `identity/`, `platform/`,
     `monitoring/`, and `identity-config/`
5. Classify missing values:
   - **Required**: direct references such as `local.name` or
     `var.constants["section"]["key"]` without a `try(...)` or documented
     fallback.
   - **Optional with default**: values accessed through `try(...)`, regex
     fallback, or explicit default logic.
   - **User decision**: environment-specific values such as IPs, domains, TLS
     certificate names/paths, storage sizes/classes, image channels, OIDC/LDAP
     names, Ceph external credentials, VM placement, or Proxmox details.
6. Apply the smallest cluster-local edits needed:
   - add missing required constants
   - add new files when the repository now expects an entire constants file
   - preserve existing local values and comments where practical
   - move values into new structures when the repo layout changed
   - add `TODO` comments for user decisions
7. Regenerate Talos assets if any of these inputs changed:
   - `constants.auto.tfvars`
   - `vms.auto.tfvars`
   - `resources.auto.tfvars`
   - `patches/machine.template.yaml`
8. Validate generated workspaces where deployment runs:
   - run generation from `clusters/<cluster>` when needed:
     `../../scripts/gen-talos-assets.sh --cluster <cluster> <skip-flags>`
   - run `tofu init` and `tofu validate` in affected `out/*` workspaces
   - if the change only affects service constants and the workspaces already
     exist, validate only the affected service workspaces
   - if a required workspace does not exist yet, say so and give the generation
     command that will create it
9. Produce a final report:
   - changed files
   - validation commands run and their result
   - every `TODO` the user must edit, with clickable file links and line numbers
   - the deployment command the user should run, or state that no deployment is
     needed

## Comparison Guidance

Prefer structural comparison over blind copying.

For `*_constants.tf`, compare top-level `locals` entries against
`clusters/sample/<file>`. If a missing local is optional in module code, add it
only when doing so improves clarity or keeps the cluster aligned with the sample
contract.

For `*.auto.tfvars`, compare the effective map shape. Preserve real VM names,
VM IDs, IP addresses, Proxmox node names, resource sizes, labels, Talos versions,
factory image IDs, and network settings unless the user explicitly asks to
change them.

When a new map entry from `clusters/sample` is clearly environment-specific,
copy the key structure but replace unsafe example content with an empty value or
reserved/example value and add a `TODO` comment.

When a value appears to have moved, keep the existing value and place it at the
new location. Remove the old location only when module code no longer consumes
it and the removal is clearly safe.

## Validation Rules

Follow normal repository rules from `AGENTS.md`:

- run scripts from `clusters/<cluster>`
- validate in generated `out/*` workspaces, not only source modules
- do not silently upgrade providers
- keep provider constraints compatible with committed lockfiles
- do not deploy on behalf of the user

If validation requires network access or local credentials and cannot be run,
state exactly which command was skipped and why.

## Deployment Command Guidance

The final deployment command must start from the cluster directory:

```bash
cd clusters/<cluster>
../../scripts/deploy.sh <minimum-skip-flags>
```

Choose skip flags by affected component:

- only root/Talos/VM changes: skip all service layers that are unaffected
- only k8s networking changes: include `--services-only` and skip Ceph,
  identity, platform, and monitoring when they are unaffected
- only Ceph constants or Rook manifests: include `--services-only` and skip
  k8s-net, identity, platform, and monitoring when they are unaffected
- only identity changes: include `--services-only` and skip Ceph, k8s-net,
  platform, and monitoring when they are unaffected
- only platform changes: include `--services-only` and skip Ceph, k8s-net,
  identity, and monitoring when they are unaffected
- only monitoring changes: include `--services-only` and skip Ceph, k8s-net,
  identity, and platform when they are unaffected

Do not include skip flags for dependencies that must be refreshed because of the
change. For example, if monitoring now depends on identity outputs that also
changed, do not skip identity.

## How To Invoke

Typical user requests that should trigger this workflow:

- `Update cluster gcs-demo to the current repo layout`
- `Bring clusters/prod in line with clusters/sample`
- `Add any new constants this repo now requires for my cluster`
- `Follow docs/agent-workflows/update-cluster-from-repo.md for gcs-demo`
