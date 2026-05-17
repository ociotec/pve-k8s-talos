def parse_cpu:
  if . == null or . == "" then null
  else tostring as $s
  | if $s | endswith("m") then ($s[:-1] | tonumber) / 1000
    elif $s | endswith("n") then ($s[:-1] | tonumber) / 1000000000
    elif $s | endswith("u") then ($s[:-1] | tonumber) / 1000000
    else $s | tonumber
    end
  end;

def parse_mem:
  if . == null or . == "" then null
  else tostring as $s
  | if $s | endswith("Ki") then ($s[:-2] | tonumber) * 1024
    elif $s | endswith("Mi") then ($s[:-2] | tonumber) * 1048576
    elif $s | endswith("Gi") then ($s[:-2] | tonumber) * 1073741824
    elif $s | endswith("Ti") then ($s[:-2] | tonumber) * 1099511627776
    elif $s | endswith("K") then ($s[:-1] | tonumber) * 1000
    elif $s | endswith("M") then ($s[:-1] | tonumber) * 1000000
    elif $s | endswith("G") then ($s[:-1] | tonumber) * 1000000000
    elif $s | endswith("T") then ($s[:-1] | tonumber) * 1000000000000
    else $s | tonumber
    end
  end;

def roundn($n): (. * $n | round) / $n;

def fmt_cpu($missing):
  if . == null then $missing
  elif . == 0 then "0"
  elif . < 1 then ((. * 1000 | round | tostring) + "m")
  else ((. | roundn(100) | tostring) | sub("\\.0$"; ""))
  end;

def fmt_mem($missing):
  if . == null then $missing
  elif . >= 1073741824 then (((. / 1073741824) | roundn(100) | tostring | sub("\\.0$"; "")) + "Gi")
  else (((. / 1048576) | round | tostring) + "Mi")
  end;

def fmt_ratio($value; $request):
  if $value == null or $request == null or $request == 0 then "n/a"
  else ((($value / $request) | roundn(100) | tostring) + "x")
  end;

def scalar($result):
  ($result.data.result[0].value[1]? // null) | if . == null then null else tonumber end;

def unique_preserve:
  reduce .[] as $item ([]; if index($item) then . else . + [$item] end);

def key($ns; $name): $ns + "/" + $name;
def workload_key($ns; $kind; $name; $container): $ns + "/" + $kind + "/" + $name + "/" + $container;

def controller_owner:
  ((.ownerReferences // []) | map(select(.controller == true)) | .[0] // null);

def pod_template:
  if .kind == "CronJob" then .spec.jobTemplate.spec.template else .spec.template end;

def workload_containers:
  (pod_template.spec.containers // [] | map({display: (.name // ""), lookup: (.name // ""), container: .}))
  +
  (pod_template.spec.initContainers // []
    | map(select((.resources.requests // null) != null or (.resources.limits // null) != null))
    | map({display: ("init:" + (.name // "")), lookup: (.name // ""), container: .}));

def project_section($ns; $workload):
  if $ns == "rook-ceph" then "rook"
  elif $ns == "s3" then "s3-storage"
  elif $ns == "monitoring" then "monitoring"
  elif $ns == "identity" then "identity"
  elif $ns == "portainer" then "platform"
  elif $ns == "ingress-nginx" or $ns == "metallb-system" or $ns == "cert-manager" then "k8s-net"
  elif ($ns | startswith("cattle-")) or $ns == "fleet-local" then "platform"
  elif $ns == "kube-system" then "k8s-net"
  else "other"
  end;

($workloads[0].items // []) as $workloadItems
| ($pods[0].items // []) as $podItems
| ($replicasets[0].items // []) as $replicaSetItems
| (reduce $replicaSetItems[] as $rs ({};
    ($rs.metadata | controller_owner) as $owner
    | if $owner != null and $owner.kind == "Deployment"
      then .[key($rs.metadata.namespace; $rs.metadata.name)] = {kind: "Deployment", name: $owner.name}
      else .
      end
  )) as $rsOwner
| (reduce ($workloadItems[] | select(.kind == "Job")) as $job ({};
    ($job.metadata | controller_owner) as $owner
    | if $owner != null and $owner.kind == "CronJob"
      then .[key($job.metadata.namespace; $job.metadata.name)] = {kind: "CronJob", name: $owner.name}
      else .
      end
  )) as $jobOwner
| (reduce $podItems[] as $pod ({};
    ($pod.metadata | controller_owner) as $owner
    | if $owner == null then .
      elif $owner.kind == "ReplicaSet" and ($rsOwner[key($pod.metadata.namespace; $owner.name)]? != null)
      then .[key($pod.metadata.namespace; $pod.metadata.name)] = $rsOwner[key($pod.metadata.namespace; $owner.name)]
      elif $owner.kind == "Job" and ($jobOwner[key($pod.metadata.namespace; $owner.name)]? != null)
      then .[key($pod.metadata.namespace; $pod.metadata.name)] = $jobOwner[key($pod.metadata.namespace; $owner.name)]
      else .[key($pod.metadata.namespace; $pod.metadata.name)] = {kind: $owner.kind, name: $owner.name}
      end
  )) as $podOwner
| (reduce ($cpu[0].data.result[]? ) as $r ({};
    ($r.metric.namespace // "") as $ns
    | ($r.metric.pod // "") as $pod
    | ($r.metric.container // "") as $container
    | if $ns == "" or $pod == "" or $container == "" or ($podOwner[key($ns; $pod)]? == null) then .
      else ($podOwner[key($ns; $pod)]) as $owner
      | (workload_key($ns; $owner.kind; $owner.name; $container)) as $k
      | .[$k].cpu = ([.[$k].cpu // 0, ($r.value[1] | tonumber)] | max)
      end
  )) as $cpuUsage
| (reduce ($mem[0].data.result[]? ) as $r ({};
    ($r.metric.namespace // "") as $ns
    | ($r.metric.pod // "") as $pod
    | ($r.metric.container // "") as $container
    | if $ns == "" or $pod == "" or $container == "" or ($podOwner[key($ns; $pod)]? == null) then .
      else ($podOwner[key($ns; $pod)]) as $owner
      | (workload_key($ns; $owner.kind; $owner.name; $container)) as $k
      | .[$k].mem = ([.[$k].mem // 0, ($r.value[1] | tonumber)] | max)
      end
  )) as $memUsage
| [
    $workloadItems[]
    | select(.kind != "Job")
    | . as $workload
    | workload_containers[]
    | . as $entry
    | ($workload.metadata.namespace) as $ns
    | ($workload.kind) as $kind
    | ($workload.metadata.name) as $name
    | (($kind + "/" + $name)) as $workloadName
    | project_section($ns; $workloadName) as $section
    | ($entry.container.resources.requests.cpu // null | parse_cpu) as $cpuRequest
    | ($entry.container.resources.requests.memory // null | parse_mem) as $memRequest
    | ($entry.container.resources.limits.cpu // null | parse_cpu) as $cpuLimit
    | ($entry.container.resources.limits.memory // null | parse_mem) as $memLimit
    | (workload_key($ns; $kind; $name; $entry.lookup)) as $uk
    | ($cpuUsage[$uk].cpu // null) as $cpuP95
    | ($memUsage[$uk].mem // null) as $memMax
    | (if $cpuP95 != null and $cpuRequest != null and $cpuRequest != 0 then ($cpuP95 / $cpuRequest) else -1 end) as $cpuRatio
    | (if $memMax != null and $memRequest != null and $memRequest != 0 then ($memMax / $memRequest) else -1 end) as $memRatio
    | (($cpuRequest == null) or ($memRequest == null)) as $missingRequest
    | (($cpuLimit == null) or ($memLimit == null)) as $missingLimit
    | (
        []
        + (if $missingRequest then ["missing requests"] else [] end)
        + (if $missingLimit then ["missing limits"] else [] end)
        + (if ($cpuRequest != null and $cpuP95 != null and $cpuP95 > $cpuRequest) then ["CPU request below p95"] else [] end)
        + (if ($memRequest != null and $memMax != null and $memMax > $memRequest) then ["memory request below max"] else [] end)
      ) as $findingsRaw
    | (if ($findingsRaw | length) == 0 then ["ok"] else $findingsRaw end) as $findings
    | (
        []
        + (if $missingRequest then ["set CPU and memory requests"] else [] end)
        + (if $missingLimit then ["review/set limits"] else [] end)
        + (if ($cpuRequest != null and $cpuP95 != null and $cpuP95 > $cpuRequest) then ["raise CPU request"] else [] end)
        + (if ($memRequest != null and $memMax != null and $memMax > $memRequest) then ["raise memory request"] else [] end)
      ) as $recommendationsRaw
    | (if ($recommendationsRaw | length) == 0 then ["no change"] else ($recommendationsRaw | unique_preserve) end) as $recommendations
    | select($includeOk or $findings != ["ok"])
    | (if $missingRequest then 0 elif $missingLimit then 1 elif $memRatio > 1 then 2 elif $cpuRatio > 1 then 3 else 4 end) as $severity
    | {
        sort: [$severity, -([$cpuRatio, $memRatio, 0] | max)],
        row: {
          "Section": $section,
          "Namespace": $ns,
          "Workload": $workloadName,
          "Container": $entry.display,
          "CPU request": ($cpuRequest | fmt_cpu("missing")),
          "CPU limit": ($cpuLimit | fmt_cpu("missing")),
          "CPU 24h p95": ($cpuP95 | fmt_cpu("n/a")),
          "CPU request ratio": fmt_ratio($cpuP95; $cpuRequest),
          "Memory request": ($memRequest | fmt_mem("missing")),
          "Memory limit": ($memLimit | fmt_mem("missing")),
          "Memory 24h max": ($memMax | fmt_mem("n/a")),
          "Memory request ratio": fmt_ratio($memMax; $memRequest),
          "Finding": ($findings | join("; ")),
          "Recommendation": ($recommendations | join("; "))
        }
      }
  ] | sort_by(.row.Section, .row.Namespace, .row.Workload, .row.Container) as $sortedRows
| (reduce ($podItems[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | .spec.containers[]?) as $container (
    {running: 0, missingRequests: 0, missingLimits: 0, cpuRequest: 0, memRequest: 0};
    ($container.resources.requests.cpu // null | parse_cpu) as $cpuRequest
    | ($container.resources.requests.memory // null | parse_mem) as $memRequest
    | ($container.resources.limits.cpu // null | parse_cpu) as $cpuLimit
    | ($container.resources.limits.memory // null | parse_mem) as $memLimit
    | .running += 1
    | .cpuRequest += ($cpuRequest // 0)
    | .memRequest += ($memRequest // 0)
    | .missingRequests += (if $cpuRequest == null or $memRequest == null then 1 else 0 end)
    | .missingLimits += (if $cpuLimit == null or $memLimit == null then 1 else 0 end)
  )) as $totals
| ($sortedRows | map(.row) | map(select(($sections | length) == 0 or (.Section as $section | $sections | index($section))))) as $allRows
| (if $showAll then $allRows else ($allRows[:$topRows]) end) as $shownRows
| {
    summary: {
      cluster: $cluster,
      prometheus: (if $skipPrometheus then "skipped" else "prometheus-api" end),
      running_containers_audited: $totals.running,
      cpu_requested_by_running_pods: ($totals.cpuRequest | fmt_cpu("0")),
      cpu_current_usage: (scalar($cpuCurrent[0]) | fmt_cpu("n/a")),
      cpu_24h_p95_aggregate: (scalar($clusterCpu[0]) | fmt_cpu("n/a")),
      memory_requested_by_running_pods: ($totals.memRequest | fmt_mem("0")),
      memory_current_usage: (scalar($memCurrent[0]) | fmt_mem("n/a")),
      memory_24h_max_aggregate: (scalar($clusterMem[0]) | fmt_mem("n/a")),
      running_containers_missing_requests: $totals.missingRequests,
      running_containers_missing_limits: $totals.missingLimits,
      rows_total: ($allRows | length),
      rows_shown: ($shownRows | length)
    },
    rows: $shownRows
  }
| if $outputFormat == "json" then .
  else
    .summary as $s
    | .rows as $rows
    | [
        "Cluster: \($s.cluster)",
        "Prometheus source: \($s.prometheus)",
        "Running containers audited: \($s.running_containers_audited)",
        "CPU requested by running pods: \($s.cpu_requested_by_running_pods)",
        "CPU current usage: \($s.cpu_current_usage)",
        "CPU 24h p95 aggregate: \($s.cpu_24h_p95_aggregate)",
        "Memory requested by running pods: \($s.memory_requested_by_running_pods)",
        "Memory current usage: \($s.memory_current_usage)",
        "Memory 24h max aggregate: \($s.memory_24h_max_aggregate)",
        "Running containers missing requests: \($s.running_containers_missing_requests)",
        "Running containers missing limits: \($s.running_containers_missing_limits)",
        "",
        "| Section | Namespace | Workload | Container | CPU request | CPU limit | CPU 24h p95 | CPU request ratio | Memory request | Memory limit | Memory 24h max | Memory request ratio | Finding | Recommendation |",
        "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"
      ]
      + ($rows | map("| \(.["Section"] | gsub("\\|"; "\\\\|")) | \(.["Namespace"] | gsub("\\|"; "\\\\|")) | \(.["Workload"] | gsub("\\|"; "\\\\|")) | \(.["Container"] | gsub("\\|"; "\\\\|")) | \(.["CPU request"]) | \(.["CPU limit"]) | \(.["CPU 24h p95"]) | \(.["CPU request ratio"]) | \(.["Memory request"]) | \(.["Memory limit"]) | \(.["Memory 24h max"]) | \(.["Memory request ratio"]) | \(.["Finding"] | gsub("\\|"; "\\\\|")) | \(.["Recommendation"] | gsub("\\|"; "\\\\|")) |"))
      + (if ($showAll | not) and $s.rows_total > $s.rows_shown then ["", "Rows total: \($s.rows_total); shown: \($s.rows_shown). Use --all or --top <n> to change this."] else [] end)
    | .[]
  end
