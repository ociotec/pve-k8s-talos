def section_for($ns):
  if $ns == "identity" then "identity"
  elif $ns == "monitoring" then "monitoring"
  elif $ns == "rook-ceph" then "rook"
  elif ($ns | test("^(cert-manager|metallb-system|ingress-nginx|kube-system)$")) then "k8s-net"
  elif ($ns | test("^(cattle-system|portainer)$")) then "platform"
  else "other"
  end;

def probe_type($probe):
  if $probe == null then "missing"
  elif $probe.httpGet then "present:httpGet"
  elif $probe.tcpSocket then "present:tcpSocket"
  elif $probe.exec then "present:exec"
  elif $probe.grpc then "present:grpc"
  else "present:unknown"
  end;

def pod_spec:
  if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
  else .spec.template.spec
  end;

def recommendation($missing_readiness; $missing_liveness; $startup):
  if $missing_readiness and $missing_liveness then "add readinessProbe and livenessProbe"
  elif $missing_readiness then "add readinessProbe"
  elif $missing_liveness then "add livenessProbe"
  elif $startup == "missing" then "consider startupProbe for slow startup"
  else "no change"
  end;

def finding($missing_readiness; $missing_liveness):
  if $missing_readiness and $missing_liveness then "missing readiness and liveness"
  elif $missing_readiness then "missing readiness"
  elif $missing_liveness then "missing liveness"
  else "ok"
  end;

def severity($finding; $startup):
  if $finding == "missing readiness and liveness" then 0
  elif $finding == "missing readiness" then 1
  elif $finding == "missing liveness" then 2
  elif $startup == "missing" then 3
  else 4
  end;

def esc:
  tostring
  | gsub("\\|"; "\\|")
  | gsub("\n"; " ");

def audit_rows:
  [
    $workloads[0].items[]
    | .metadata.namespace as $ns
    | .kind as $kind
    | .metadata.name as $name
    | section_for($ns) as $section
    | select(($sections | length) == 0 or ($sections | index($section)))
    | (pod_spec.containers // [])[]
    | probe_type(.readinessProbe) as $readiness
    | probe_type(.livenessProbe) as $liveness
    | probe_type(.startupProbe) as $startup
    | ($readiness == "missing") as $missing_readiness
    | ($liveness == "missing") as $missing_liveness
    | finding($missing_readiness; $missing_liveness) as $finding
    | {
        section: $section,
        namespace: $ns,
        workload: ($kind + "/" + $name),
        container: .name,
        readiness: $readiness,
        liveness: $liveness,
        startup: $startup,
        finding: $finding,
        recommendation: recommendation($missing_readiness; $missing_liveness; $startup),
        severity: severity($finding; $startup)
      }
  ]
  | sort_by(.severity, .section, .namespace, .workload, .container);

def render_report($report):
  $report.summary as $s
  | "Audited containers: \($s.audited_containers)\n"
    + "Missing readiness probes: \($s.missing_readiness)\n"
    + "Missing liveness probes: \($s.missing_liveness)\n"
    + "Missing startup probes: \($s.missing_startup)\n"
    + "Compliant readiness/liveness: \($s.compliant_readiness_liveness)\n"
    + (if $report.truncated then "\nTable truncated to worst rows.\n" else "\n" end)
    + "\n| Section | Namespace | Workload | Container | Readiness | Liveness | Startup | Finding | Recommendation |\n"
    + "|---|---|---|---|---|---|---|---|---|\n"
    + (
        $report.rows
        | map("| \(.section|esc) | \(.namespace|esc) | \(.workload|esc) | \(.container|esc) | \(.readiness|esc) | \(.liveness|esc) | \(.startup|esc) | \(.finding|esc) | \(.recommendation|esc) |")
        | join("\n")
      );

(audit_rows) as $all
| ($all | map(select($includeOk or .finding != "ok"))) as $rows
| {
    summary: {
      audited_containers: ($all | length),
      missing_readiness: ($all | map(select(.readiness == "missing")) | length),
      missing_liveness: ($all | map(select(.liveness == "missing")) | length),
      missing_startup: ($all | map(select(.startup == "missing")) | length),
      compliant_readiness_liveness: ($all | map(select(.finding == "ok")) | length)
    },
    truncated: (($rows | length) > $topRows and ($showAll | not)),
    rows: (if $showAll then $rows else $rows[:$topRows] end)
  } as $report
| if $outputFormat == "json" then $report else render_report($report) end
