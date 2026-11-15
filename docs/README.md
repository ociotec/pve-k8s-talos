# Documentation

Start with the [repository README](../README.md) for setup and deployment.
Each document owns its status, scope and decisions; this index only provides
navigation. Add new documentation here when creating it.

## Specifications and architecture

- [Worker CPU and memory headroom](worker-resource-headroom.md)
- [Automatic worker resource reservations](worker-resource-reservations.md)
- [Workload admission requirements](workload-admission-policy.md)
- [Automatic node remediation and stateful workload recovery](automatic-node-remediation.md)
- [External Ceph storage](ceph-external-storage.md)
- [Site bootstrap node and offline delivery](site-bootstrap-node.md)
- [VPA and Goldilocks](vpa-goldilocks.md)

## Operations and reference

- [Cluster deployment status and development consolidation](deployment-status.md)
- [Rancher, Portainer and Grafana authentication with Keycloak](rancher-keycloak-auth.md)
- [Grafana Helm workload migration](grafana-helm-migration.md)
- [Grafana Operator resource provisioning](grafana-operator-provisioning.md)
- [Prometheus CPU and memory sizing](prometheus-resource-sizing.md)

## Evaluations

- [Ingress gateways](ingress-gateway-evaluation.md)
- [S3-compatible storage](s3-storage-evaluation.md)

## Agent procedures

- [Agent workflows](agent-workflows/), used together with [AGENTS.md](../AGENTS.md)
