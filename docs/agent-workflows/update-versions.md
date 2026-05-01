# Update Versions Workflow

Use this workflow when the user wants an inventory of versioned components in this repository, comparing current versions found in code with the latest stable upstream versions, and optionally applying a follow-up update.

This workflow is repo-local guidance for agents. It is not a globally installed Codex skill.

## Scope

Handle repositories where versions may be declared in:

- Terraform/OpenTofu `required_providers`
- `.terraform.lock.hcl`
- Helm values or chart versions
- Kubernetes manifests with container image tags or digests
- Cluster constants files such as `*.tfvars`, `*_constants.tf`, `values.yaml`, or similar
- Vendored manifests that embed component versions in labels, annotations, or image references

## Required Behavior

- Always respond in English unless the user explicitly requests another language.
- Present the result as a table unless the user asks for a different format.
- Compare the version currently pinned in the repository against the latest stable upstream release.
- Use official or primary sources for the latest version:
  - vendor docs
  - official release pages
  - official registries
  - upstream GitHub releases when they are the canonical release source
- Exclude prereleases, betas, release candidates, alphas, and nightly builds from the proposed version.
- If the repository is already on the latest stable version:
  - leave `Proposed stable new version` empty
  - leave `Note` empty
- After the table, ask whether to apply updates:
  - all updates
  - no updates
  - partial updates
- Once the user chooses `all updates` or `partial updates`, do not ask again for routine execution steps such as:
  - `tofu init -upgrade`
  - `tofu validate`
  Treat those as part of the normal update workflow and proceed automatically.

## Output Format

Use this column set unless the user requests a different shape:

| Component | Version source | Current version in repo | Proposed stable new version | Note |

Keep the table in English.

## Workflow

1. Inspect the repository and locate all versioned elements that are actually pinned in code.
2. Treat the in-repo pinned value as the current version, not README examples unless they are the source of truth.
3. Group duplicate declarations that represent the same effective component when that improves clarity.
4. Verify the latest stable upstream version from official or primary sources.
5. Build the table.
6. At the end, ask a concise follow-up question in English:
   `Do you want me to apply all updates, no updates, or only a partial set?`

If the user chooses a partial update, ask them to name the components or version groups to update.

If the user chooses all or partial updates, execute the required repo validation workflow directly without an extra conversational confirmation step.

## Selection Rules

- Prefer effective runtime version pins over loose constraints when both exist.
- For Terraform/OpenTofu providers:
  - if a lockfile exists for the relevant workspace, use the locked version as current
  - also inspect the constraint to understand whether an upgrade would require changing source files
- For container images:
  - use the explicit image tag as current
  - if the image is pinned by digest and tag, preserve both concepts in the note only if relevant
- For vendored multi-image manifests such as cert-manager or ingress-nginx:
  - inventory the parent component once when the images clearly belong to one release train
- For products with multiple channels, prefer stable GA only
  - choose LTS only if the repo is clearly following LTS; otherwise choose latest stable GA and mention channel differences in `Note`

## Notes Guidance

Use `Note` only when useful, for example:

- `Latest stable is LTS; newer STS also exists`
- `Major upgrade`
- `Project archived; consider migration`
- `Upgrade requires lockfile refresh`

Do not add a note when there is no update proposal.

## Repo-Specific Validation

Apply the normal repository rules from `AGENTS.md`, especially:

- do not silently force provider upgrades in normal flows
- keep `required_providers` constraints compatible with committed lockfiles unless intentionally changing them
- validate in the same generated workspace where deployment runs, typically `clusters/<cluster>/out/*`
- if a version change touches deployment orchestration, generation, or shared module behavior, run the corresponding repo validation steps from `AGENTS.md`

## How To Invoke

Typical user requests that should trigger this workflow:

- `Audit pinned versions in this repo`
- `Check if the repo is behind on providers or component versions`
- `Propose stable updates for the versions used here`
- `Follow docs/agent-workflows/update-versions.md`
