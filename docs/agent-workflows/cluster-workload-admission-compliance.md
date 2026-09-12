# Cluster Workload Admission Compliance Workflow

Use this workflow to inspect an existing repository cluster for compliance with
the workload admission requirements defined in
[`docs/workload-admission-policy.md`](../workload-admission-policy.md).

This workflow is repository-local guidance for agents. It is not a globally
installed Codex skill.

## Required input

A cluster name is required. The cluster directory, kubeconfig, and optional
report output are all cluster-specific.

If the user does not provide a cluster name, ask for it before running commands.

## Scope

Inspect live Kubernetes resources, not only repository manifests.

| Requirement | Included resources | Included containers |
| --- | --- | --- |
| CPU and memory resources | Deployment, StatefulSet, DaemonSet, Job, CronJob | `containers` and `initContainers` |
| Readiness and liveness probes | Deployment, StatefulSet, DaemonSet | Regular `containers` only |

For CronJobs, inspect
`.spec.jobTemplate.spec.template.spec`. For all other included resources,
inspect the normal pod template. Exclude `ephemeralContainers`.

A resource-compliant container defines all four fields:

```yaml
resources.requests.cpu
resources.requests.memory
resources.limits.cpu
resources.limits.memory
```

A probe-compliant regular service container defines both `readinessProbe` and
`livenessProbe`. Jobs and CronJobs are probe-not-applicable, not probe-failed.

The audit checks field presence and valid exception metadata. It does not assess
whether resource quantities are appropriately sized, or whether a probe endpoint
is semantically correct, unless the user explicitly asks for those additional
analyses.

## Safety and deployment status

- Use the user's language for the chat response. Generated Markdown reports are
  written in English unless the user asks for another language.
- Do not apply, modify, restart, or deploy any Kubernetes resource.
- Do not run `tofu plan`, `tofu apply`, or `scripts/deploy.sh`.
- Load the cluster environment before every cluster-local command:
  `direnv exec . <command>`, from `clusters/<cluster>`.
- Do not print secrets, private URLs, kubeconfig data, or certificate material.
- Before inspection, query
  `../../scripts/deployment-status.sh show` and follow the deployment-status
  comparison rules in `AGENTS.md`. If the Kubernetes API is unavailable,
  state that live compliance is unknown and do not use a local status file as a
  substitute.

## Exception evaluation

Evaluate exception annotations on the workload controller's
`metadata.annotations`, never on its pod template:

- `policy.pve-k8s-talos.io/allow-missing-resources: "true"`
- `policy.pve-k8s-talos.io/allow-missing-probes: "true"`
- `policy.pve-k8s-talos.io/exception-reason`
- `policy.pve-k8s-talos.io/exception-owner`
- `policy.pve-k8s-talos.io/exception-expires`

An active exception requires either allow annotation with literal value
`"true"`, a non-empty reason and owner, and an ISO date expiry that has not
passed. Treat any malformed, missing, unauthorized, or expired exception as
invalid and therefore non-compliant. Authorization can only be confirmed from
the configured Kyverno policy and RBAC identities; when those are not available,
render its authorization status as `not verified`, not `valid`.

A valid resource exception affects only the resource result. A valid probe
exception affects only the probe result. A valid exception is a distinct status,
not full compliance.

## Data collection

1. Identify the cluster directory and verify Kubernetes API access:

   ```sh
   cd clusters/<cluster>
   direnv exec . kubectl --kubeconfig out/kubeconfig get nodes
   ```

2. Inspect cluster-side deployment provenance:

   ```sh
   direnv exec . ../../scripts/deployment-status.sh show
   ```

3. Read the Kyverno and Policy Reporter constants from
   `k8s_net_constants.tf` and `monitoring_constants.tf`. Report whether
   audit, enforce, and Policy Reporter are configured as enabled, disabled, or
   unavailable in the current source. This configuration status must not replace
   the live field-presence audit.

4. Fetch the complete workload inventory in JSON:

   ```sh
   direnv exec . kubectl --kubeconfig out/kubeconfig      get deployment,statefulset,daemonset,job,cronjob -A -o json
   ```

5. Parse the JSON using a temporary, reviewable analysis script rather than a
   long nested shell command. For every workload, retain:
   - namespace, kind, and name;
   - each regular and init container name;
   - the four resource field-presence values;
   - readiness and liveness field presence when applicable;
   - all exception annotations and their evaluated status.

6. If Kyverno is installed, collect its current reports separately:

   ```sh
   direnv exec . kubectl --kubeconfig out/kubeconfig get policyreport -A
   direnv exec . kubectl --kubeconfig out/kubeconfig get clusterpolicyreport
   ```

   Use these reports as corroborating operational evidence. Do not treat their
   absence as compliance: policies may be disabled, report generation may be
   delayed, or the resource may fall outside a policy's match scope. For an
   enforced rejection, inspect Kubernetes Events and Kyverno metrics when the
   user asks about rejected submissions; a denied object may not have a
   persistent PolicyReport because it was never created.

## Result model

Evaluate each applicable policy independently:

- `compliant`: every applicable container has all required fields.
- `non-compliant`: one or more applicable fields are missing.
- `excepted`: fields are missing but a valid, unexpired exception applies.
- `invalid exception`: fields are missing and an exception is malformed,
  expired, incomplete, or cannot be authorized.
- `not applicable`: probes on Jobs and CronJobs.
- `unknown`: the API, object data, or policy authorization evidence was not
  available.

The overall workload result is:

1. `non-compliant` or `invalid exception` if either policy has that result.
2. `excepted` if neither policy is failing but at least one valid exception
   applies.
3. `compliant` if all applicable policies comply.
4. `unknown` if no more definite result is available.

## Chat output

Start with a concise summary:

- Kyverno audit/enforce configuration status.
- Policy Reporter configuration status.
- total workloads and containers audited;
- count of non-compliant workloads;
- count of invalid and valid exceptions;
- count fully compliant with every applicable policy;
- count of Jobs/CronJobs where probes are not applicable;
- whether live Kyverno reports corroborate the findings.

Then render Markdown tables in this order:

1. Non-compliant and invalid-exception workloads.
2. Validly excepted workloads.
3. Fully compliant workloads.
4. Probe-not-applicable Jobs and CronJobs, if they are otherwise resource
   compliant.

Use this column set:

| Namespace | Workload | Container(s) | Resources | Probes | Exception | Overall result | Finding |

Rules:

- Render the workload as `<kind>/<name>`.
- Include one row per affected container for a failure or exception. For fully
  compliant workloads, one aggregate row is sufficient when all containers have
  the same result.
- In the resource column, list the missing fields, for example
  `missing requests.cpu, limits.memory`.
- In the probes column, use `ready + live`, `missing readiness`,
  `missing liveness`, `missing both`, or `n/a (Job)`.
- In the exception column, show `none`, `resources until YYYY-MM-DD`,
  `probes until YYYY-MM-DD`, or the invalidity reason.
- Sort failures first, then invalid exceptions, valid exceptions, compliant
  workloads, and probe-not-applicable workloads. Sort each group by namespace,
  kind, and name.

For a chat response, show all failures and exceptions, followed by at most 100
compliant/not-applicable rows. State exactly when the display is truncated and
offer a complete Markdown report.

## Optional Markdown report

Create a report only when the user explicitly requests a file. Write the full,
untruncated Markdown result to:

```text
clusters/<cluster>/out/reports/workload-admission-compliance-<UTC timestamp>.md
```

The report directory is generated runtime output and must not be committed.
Include:

1. report timestamp and cluster identifier;
2. policy configuration and live-access status;
3. counts and result definitions;
4. full untruncated tables;
5. a separate appendix listing each container's missing fields;
6. a short note distinguishing live PolicyReport evidence from the independent
   field-presence audit.

Link the generated local file in the final response. Do not include sensitive
connection details or credentials in the report.

## Completion

Always state that this workflow is read-only and that it did not deploy policy
changes. If repository files were not changed, state that no deployment is
needed. If a future policy implementation is changed as a result of the audit,
provide the minimum authorized deployment command for the affected section or
sections; do not run it.

