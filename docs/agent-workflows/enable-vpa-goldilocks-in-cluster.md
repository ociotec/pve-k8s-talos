# Enable VPA and Goldilocks in a Cluster

Use this workflow when the user wants to prepare a repository cluster for
Vertical Pod Autoscaler (VPA) and Goldilocks.

This workflow is repo-local guidance for agents. It is not a globally installed
Codex skill.

## Consolidation Status

Only the read-only discovery phase, Nexus registry onboarding, Talos mirror
enablement, and registry-access validation have been consolidated using the
registry path of a real cluster. Follow this document only through those
phases. Do not infer VPA or Goldilocks installation, configuration, deployment,
validation, or rollback steps that are not yet documented here.

Extend this workflow only after a new step has been completed successfully on a
real cluster and its result has been reviewed. Keep all instructions generic:
do not include real cluster names, private hostnames, private IP addresses,
credentials, or private URLs.

## Required Input

The cluster name is required because its environment, kubeconfig, generated
workspaces, constants, and deployment status are cluster-specific.

If the user does not provide a cluster name, ask for it before accessing a real
cluster.

## Required Behavior

- Run cluster-local commands from `clusters/<cluster>`.
- Load the cluster environment with `direnv exec . <command>` when `.envrc`
  exists. Use `bash -lc 'source .envrc; <command>'` only when direnv cannot be
  used.
- Treat `kube-system/pve-k8s-talos-deployment-status` as the authoritative live
  deployment record. Do not use the deprecated local `.repo-status.json` as
  deployment evidence.
- If the Kubernetes API is unavailable, report live deployment status as
  unknown.
- Keep cluster inspection read-only. Do not create CRDs, namespaces, labels, Helm
  releases, Keycloak clients, secrets, ingresses, or workloads.
- Pull an image into a node CRI cache only when the user explicitly authorizes
  that validation. State that the pull changes only the selected node's image
  cache and may remain there until runtime garbage collection removes it.
- Do not run `tofu plan`, `tofu apply`, `scripts/deploy.sh`, or ad hoc
  `kubectl apply` commands during discovery.
- Do not print secrets, private endpoints, kubeconfigs, Talos configuration, or
  OpenTofu state contents.
- Report observed facts separately from decisions that remain pending.

## Registry Terminology

Keep these layers distinct in analysis and reporting:

- **Corporate HTTP(S) proxy**: an outbound network intermediary configured
  through Talos `machine.env.http_proxy` and `machine.env.https_proxy`.
- **Nexus Docker proxy repository**: a pull-through cache for one upstream
  container registry.
- **Nexus Docker group**: the client-facing endpoint that aggregates hosted and
  proxy repositories.
- **Talos registry mirror**: the mapping from an upstream registry hostname to
  the Nexus Docker group endpoint.

A Talos mirror mapping does not create the corresponding Nexus proxy
repository. The Nexus proxy must exist and belong to the exposed Docker group
before the mapping is enabled in a cluster.

## Consolidated Nexus Registry Onboarding

Use this phase only when an image comes from an upstream registry that the
client-facing Nexus Docker group cannot already serve. Nexus changes affect all
clients of that shared group, so inspect the existing configuration before
mutating it.

1. Resolve the exact registry hostname from the pinned image reference. Do not
   create a proxy for a regional hostname copied from an example unless it is
   the hostname used by the selected image.

2. Read the Nexus repository inventory and the full configuration of the
   client-facing Docker group. Confirm that no existing proxy already covers
   the upstream and record the current member order.

3. Read the live Nexus OpenAPI document before constructing requests. Use the
   request schemas advertised by that instance; do not infer them from another
   Nexus version. The endpoints used by the consolidated procedure are:

   - `POST /service/rest/v1/blobstores/file`
   - `POST /service/rest/v1/repositories/docker/proxy`
   - `PUT /service/rest/v1/repositories/docker/group/{repositoryName}`

4. Read an existing Docker proxy with equivalent behavior and use it as the
   configuration template. The consolidated configuration uses:

   - a dedicated file blob store for the upstream registry;
   - strict content-type validation;
   - an online Docker proxy whose remote URL is the upstream registry root;
   - the existing proxy cache and negative-cache lifetimes;
   - automatic blocking enabled and manual blocking disabled;
   - the Nexus trust store for outbound TLS;
   - Docker index type `REGISTRY`;
   - the same Docker V1 and authentication behavior as the existing proxy;
   - foreign-layer caching disabled when it is disabled in the template.

5. Create the dedicated file blob store. Read it back through the API and
   confirm its path before creating the repository.

6. Create the Docker proxy repository. Read it back and compare every relevant
   field with the intended template, including the remote URL, blob store,
   cache settings, HTTP client, Docker attributes, and Docker proxy attributes.

7. Retrieve the Docker group again immediately before updating it. Build the
   update from that live response, preserve its storage and Docker connector
   settings, preserve all existing member names and their order, and append the
   new proxy only if it is not already present. Read the group back after the
   update and verify the final member list.

8. Request the exact pinned image manifest through the client-facing group
   endpoint, using the appropriate OCI and Docker manifest `Accept` types. A
   successful `HTTP 200` confirms that the group can route the repository and
   populate the new proxy cache. A registry-root response is not a substitute
   for this test.

Keep Nexus credentials out of URLs, command arguments, output, shell tracing,
and temporary files. Load them from the approved service configuration and pass
them to the HTTP client using its protected configuration mechanism. Do not
print the private Nexus URL in reports or shared documentation.

## Consolidated Talos Mirror Enablement

Use this phase only after the exact pinned image manifest returns `HTTP 200`
through the client-facing Nexus Docker group.

1. Add the upstream registry hostname to the cluster's
   `constants.auto.tfvars` registry mirror map. Reuse the same client-facing
   Nexus Docker group endpoint as the cluster's existing registry entries. Do
   not add a direct upstream URL or a URL for the dedicated Nexus proxy
   repository.

2. Regenerate the Talos assets from `clusters/<cluster>` without excluding
   deployed service sections whose hostnames must remain in `no_proxy`:

   ```bash
   direnv exec . ../../scripts/gen-talos-assets.sh --cluster <cluster>
   ```

   Add `--skip-*` flags only for sections that are intentionally absent and
   whose hostnames must be excluded from the rendered Talos configuration.

3. Validate the real root workspace and review a plan without applying it:

   ```bash
   direnv exec . tofu -chdir=out/root init -input=false
   direnv exec . tofu -chdir=out/root validate
   direnv exec . tofu -chdir=out/root plan -input=false
   ```

   Treat regenerated `local_sensitive_file` resources as local machineconfig
   files, not VM replacements. Confirm separately that no VM resource is being
   created, deleted, or replaced. Inspect any pre-existing Talos configuration
   drift, such as `no_proxy` changes, rather than attributing all machineconfig
   differences to the new mirror.

4. Commit and push the platform and cluster source changes required by the
   normal synchronized deployment flow. Obtain explicit permission for the
   named cluster and the Talos/Kubernetes section before deploying.

5. Deploy only Talos/Kubernetes from `clusters/<cluster>`:

   ```bash
   direnv exec . ../../scripts/deploy.sh -t
   ```

   Do not add service `--skip-*` flags merely to prevent service deployment;
   `-t` exits before all Kubernetes service sections. In this mode, skip flags
   affect only which service hostnames are included in the generated Talos
   `no_proxy` value.

6. Let the deployment reconcile staged machine configurations sequentially.
   Confirm that every worker and control-plane node recovers with the desired
   Talos configuration and returns `Ready`. Do not interrupt the deployment
   while a node is rebooting unless a documented failure condition requires
   operator intervention.

7. After success, verify all of the following:

   - both repositories are clean and synchronized with their upstream branches;
   - development mode is inactive;
   - the live deployment record advanced only the `k8s` section;
   - all service section deployment records retained their previous revisions;
   - the runtime-state commit was created and pushed by the normal deployment
     flow.

8. Select a worker that does not already contain the exact pinned image, then
   pull it through Talos CRI and confirm the image reference and digest:

   ```bash
   task_node_ip="$(kubectl get node <worker> \
     -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
   talosctl image pull -n "${task_node_ip}" \
     <registry>/<repository>/<image>:<version>
   talosctl image list -n "${task_node_ip}"
   ```

   With `skipFallback` enabled for the mirror, a successful pull on a node that
   did not have the image cached validates the Talos-to-Nexus path. State that
   this validation leaves the image in that node's CRI cache until runtime
   garbage collection removes it.

## Consolidated Discovery Workflow

1. Confirm that both repositories are clean before starting:

   ```bash
   git status --short
   git -C clusters/<cluster> status --short
   ```

   Preserve all pre-existing changes. A dirty worktree does not authorize an
   agent to discard, overwrite, commit, or deploy those changes.

2. From `clusters/<cluster>`, read the live deployment record:

   ```bash
   direnv exec . ../../scripts/deployment-status.sh show
   ```

   Record whether a development deployment is active and the revisions stored
   for sections relevant to the requested work. Compare recorded revisions with
   the current platform and cluster repository `HEAD` values as required by
   `docs/deployment-status.md` and `AGENTS.md`. Classify documentation-only and
   runtime-state-only differences separately from operational drift.

3. Confirm Kubernetes access and inventory the node Kubernetes versions:

   ```bash
   direnv exec . kubectl get nodes \
     -o 'custom-columns=NAME:.metadata.name,K8S:.status.nodeInfo.kubeletVersion' \
     --no-headers
   ```

   Do not treat successful local file inspection as evidence that the live
   Kubernetes API is reachable.

4. Confirm that Metrics Server exists and has a ready replica:

   ```bash
   direnv exec . kubectl -n kube-system get deployment metrics-server \
     -o 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image' \
     --no-headers
   ```

   Record the observed image and readiness without changing the deployment.
   Treat a missing or unready Metrics Server as a discovery finding, not as
   authorization to install or repair it.

5. Check whether the VPA API is already installed:

   ```bash
   direnv exec . kubectl get crd \
     verticalpodautoscalers.autoscaling.k8s.io \
     -o name
   ```

   A Kubernetes `NotFound` response means the VPA CRD is absent. Record that
   result; do not install the CRD during this workflow phase.

6. Identify every upstream registry required by the proposed components. Check
   whether the client-facing Nexus Docker group already contains a proxy
   repository that can serve each new upstream registry. Nexus administration
   is separate from the Talos cluster configuration. If the proxy repository is
   absent and the user has authorized the shared Nexus change, follow
   **Consolidated Nexus Registry Onboarding** before changing the cluster.
   Otherwise, record it as a prerequisite and stop before enabling the mirror.

   Before adding a Talos mirror mapping, test whether the Nexus Docker group can
   serve the exact image repository and manifest path. A successful
   registry-root request alone is insufficient evidence that the image is
   available.

   Treat a successful manifest response as evidence that the mirror supports
   the repository. Treat `404` as unsupported and do not add the mapping when
   `skipFallback` is enabled, because that would prevent the runtime from
   falling back to the canonical registry.

7. When the user wants to distinguish the corporate HTTP(S) proxy from Nexus
   registry caching, use an existing running pod that already contains an HTTPS
   client. Force the client to bypass corporate proxy environment variables and
   query each upstream registry's `/v2/` endpoint. Do not create a diagnostic
   workload merely to perform this check.

   Registry API responses such as `200` or `401` prove that DNS, TCP, TLS, and
   the remote registry endpoint were reached. If the diagnostic container has
   an incomplete CA bundle, a second request that disables certificate
   verification may be used only to distinguish routing from trust-store
   failures. Report that limitation explicitly; never recommend disabling TLS
   verification in the deployed configuration.

8. With explicit user authorization, verify the real node runtime against the
   exact pinned image on one worker. Resolve the node address from Kubernetes
   without hardcoding it, then use Talos CRI image management:

   ```bash
   task_node_ip="$(kubectl get node <worker> \
     -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
   talosctl image pull -n "${task_node_ip}" <registry>/<repository>/<image>:<version>
   talosctl image list -n "${task_node_ip}"
   ```

   Confirm that the exact image reference and digest appear in the CRI image
   list. Do not deploy a Pod as part of this validation. A successful pull with
   the current Talos environment proves that the current path works; it does not
   by itself prove whether an inherited proxy was used or can be removed.

9. Report the discovery result using this table:

   | Check | Result | Evidence | Consequence |
   | --- | --- | --- | --- |
   | Kubernetes API | reachable / unavailable | node query | continue / live status unknown |
   | Deployment status | current / older / unknown | deployment-status ConfigMap | baseline for later work |
   | Development mode | inactive / active / unknown | deployment-status ConfigMap | normal work allowed / preserve local state |
   | Kubernetes versions | observed versions | node inventory | compatibility input |
   | Metrics Server | ready / unready / absent | kube-system Deployment | prerequisite present / unresolved prerequisite |
   | VPA CRD | present / absent | CRD query | existing installation requires review / no VPA installed |
   | Direct registry egress | reachable / blocked / trust failure | corporate-proxy-bypassed `/v2/` request | direct route available / unresolved network or CA issue |
   | Nexus Docker group | image available / unsupported / not configured | exact manifest request | Talos mirror mapping allowed / mapping must not be enabled |
   | Runtime image pull | successful / failed / not authorized | Talos CRI image list | current runtime path validated / unresolved |

10. Stop after reporting the discovery and registry results. State explicitly
   that VPA and Goldilocks installation and deployment phases are not yet
   consolidated in this workflow.

## Output Requirements

- Identify the target cluster without reproducing its private endpoints.
- Report whether live deployment status was available.
- Call out operationally stale relevant sections before proposing later work.
- Report the Kubernetes versions, Metrics Server readiness, and VPA CRD state.
- Distinguish direct registry reachability, mirror support, and a real runtime
  image pull; do not present one as proof of the others.
- List unresolved prerequisites or conflicts without attempting to remediate
  them.
- State that no deployment is needed when the work was limited to discovery.

## How To Invoke

Typical requests that should use the currently consolidated portion of this
workflow:

- `Check whether <cluster> is ready for VPA and Goldilocks`
- `Inspect the existing VPA prerequisites in <cluster>`
- `Start the VPA and Goldilocks adoption workflow for <cluster>`
- `Follow docs/agent-workflows/enable-vpa-goldilocks-in-cluster.md for <cluster>`
