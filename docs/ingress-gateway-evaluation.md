# Ingress Gateway Evaluation

Status: 📝 proposed architecture; no implementation decision has been applied.

## Agreed Inputs and Decisions

These are evaluation inputs agreed with the platform owner, not assumptions made
by the implementation.

### Hard Requirements

| ID | Requirement or constraint | Decision impact |
|---|---|---|
| R1 | Open-source license suitable for commercial projects, with no mandatory paid tier or complex reciprocal obligations | Excludes proprietary-only features from the required design |
| R2 | Mature, commonly deployed project with credible maintainers | Avoid niche GraphQL-specific gateways unless they provide a decisive benefit |
| R3 | Private network, but production-grade security controls remain required | Internal placement does not justify relaxed TLS, identity, or header trust |
| R4 | GraphQL queries, mutations, and `graphql-transport-ws` subscriptions; REST is also present | WebSocket compatibility and long-lived connections are mandatory |
| R5 | Requests and responses may exceed 1 MiB | Body-size limits must be explicit and tested |
| R6 | At least 100 requests/s in total; 1000 requests/s is the preferred design target | Capacity must be validated before production migration |
| R7 | At least two replicas, with three preferred for the critical gateway data plane | The gateway is treated as critical infrastructure |
| R8 | MetalLB, TLS, Prometheus metrics, access logs, and equivalent distributed tracing | Observability cannot regress during migration |
| R9 | Prefer standard Gateway API resources; CRDs are accepted only for missing standard features | `Gateway` and `HTTPRoute` form the portable routing layer |
| R10 | Preserve current redirects, rewrites, CORS, authentication, and proxy behavior | Annotation inventory must be mapped route by route |
| R11 | Keycloak and oauth2-proxy flows must retain their public issuer, callbacks, cookies, and forwarded scheme | Identity routes are migrated late and require dedicated validation |
| R12 | No new DNS records can be created; existing names resolve through one wildcard record to the current MetalLB IP | Parallel migration by DNS name or DNS weighting is unavailable |
| R13 | No CNI replacement in this change | Cilium Gateway API is not an immediate candidate |

### Accepted Trade-offs

| ID | Agreed position | Consequence |
|---|---|---|
| T1 | Resource reservations may increase beyond the current ingress-nginx footprint | Envoy Gateway, APISIX, and other richer options remain eligible |
| T2 | Initial sizing may use estimates; benchmarking is deferred | Estimates are planning values, not acceptance evidence |
| T3 | Advanced generic limits should be provided by the gateway where practical | Application-specific GraphQL authorization and cost controls still remain in the application |
| T4 | Equivalent dashboards may replace the existing dashboards | Metrics, logs, and traces matter more than dashboard continuity |

### Migration Decisions

| ID | Decision | Status |
|---|---|---|
| D1 | Put the new gateway on the original MetalLB IP | ✅ Agreed direction |
| D2 | Forward unmatched traffic from the new gateway to ingress-nginx | ✅ Agreed migration mechanism |
| D3 | Migrate routes incrementally, with Keycloak after lower-risk routes | ✅ Agreed sequencing |
| D4 | Keep ingress-nginx only until fallback traffic reaches zero | ✅ Retirement criterion |
| D5 | Evaluate and document first; do not change the clusters yet | ⏳ Current phase |

⚠️ External driver: ingress-nginx was retired in March 2026 and no longer receives
fixes.

## Current Shape

Two representative real clusters were inspected without recording private
hostnames or addresses:

| Item | Cluster A | Cluster B |
|---|---:|---:|
| Ingress resources | 458 | 378 |
| Rewrite annotations | 447 | 367 |
| CORS-enabled routes | 218 | 178 |
| ingress-nginx replicas | 3 | 3 |
| Observed CPU total | 27m | 42m |
| Observed memory total | 517 MiB | 635 MiB |
| Reserved CPU total | 300m | 300m |
| Reserved memory total | 2304 MiB | 2304 MiB |

Current request path:

```text
Wildcard DNS
    |
    v
MetalLB fixed IP
    |
    v
ingress-nginx
    |
    +--> TLS and redirects
    +--> regex rewrites and forwarded prefixes
    +--> CORS
    +--> oauth2-proxy and Basic Auth
    +--> application Services
```

## Gateway API Model

`HTTPRoute` is a routing API, not a proxy. A Gateway API controller is still
required.

```text
GatewayClass --> selects the controller
      |
Gateway      --> owns listeners, addresses, and TLS
      |
HTTPRoute    --> matches host/path/header and selects backends
      |
Policy/CRD   --> authentication, limits, rewrites, and observability
```

Prefer standard Gateway API resources. Use implementation-specific policies
only where the standard does not cover existing behavior.

## Candidate Summary

Legend: 🟢 preferred · 🟡 retained alternative · ⚪ evaluated · 🔴 out of scope.

| Status | Candidate | License | Gateway API | ✅ Main benefit | ⚠️ Main concern |
|---|---|---|---|---|---|
| 🟢 | Envoy Gateway | Apache-2.0 | Strong conformance | Broad OSS security and observability policies | Higher resource use |
| 🟡 | Traefik Proxy | MIT | Core plus selected extensions | Small, simple deployment | More vendor CRDs; advanced shared limits need extra components |
| 🟡 | Apache APISIX | Apache-2.0 | Partial support | OSS GraphQL-aware plugins | More components and lower Gateway API maturity |
| ⚪ | NGINX Gateway Fabric | Apache-2.0 | Strong conformance | Familiar NGINX data plane | JWT and OIDC require NGINX Plus |
| ⚪ | HAProxy Ingress | Apache-2.0 | Conformant implementation | Efficient data plane | Smaller policy and Gateway API ecosystem |
| 🔴 | Cilium Gateway API | Apache-2.0 | Strong conformance | Integrated eBPF networking | Requires replacing Flannel; out of current scope |

## Resource Estimates

These are planning estimates, not benchmark results. They assume three data
plane replicas, about 800 routes, metrics, logs, and tracing.

| Candidate | Suggested reserved CPU | Suggested reserved memory |
|---|---:|---:|
| Traefik | 300m | 768 MiB |
| Envoy Gateway, local policies | 500-700m | 2.5-3 GiB |
| Envoy Gateway, global rate limiting | 800m-1500m | 3.5-4.5 GiB |
| NGINX Gateway Fabric | 500-800m | 2-3 GiB |
| APISIX with production dependencies | 1-2 CPU | 4-6 GiB |

Proposed Envoy baseline:

| Component | Replicas | Per replica | Approximate total |
|---|---:|---:|---:|
| Envoy proxy | 3 | 100m / 512 MiB | 300m / 1536 MiB |
| Shutdown manager | 3 | 10m / 32 MiB | 30m / 96 MiB |
| Envoy Gateway controller | 2 | 100m / 512 MiB | 200m / 1 GiB |
| Total |  |  | 530m / 2656 MiB |

Repository policy requires memory requests and limits to be equal when these
workloads are implemented.

## GraphQL Constraints

- HTTP queries and mutations can be limited by identity, address, route,
  request count, body size, concurrency, and duration.
- Subscription clients use `graphql-transport-ws`.
- The subscription JWT is sent in the WebSocket `connection_init` message,
  after the HTTP upgrade. The gateway cannot authorize it from the handshake
  alone.
- JWT validation and role authorization must remain in the GraphQL application.
- Query depth, list cardinality, resolver fan-out, and true execution cost must
  be enforced in the application.
- APISIX `graphql-limit-count` charges HTTP POST requests by AST depth, but it
  does not cover subscriptions and depth is not a complete cost model.

## Proposed Architecture

Use Envoy Gateway as the primary candidate. Keep Traefik as the low-resource
fallback and APISIX as a future GraphQL-specialist candidate.

Target state:

```text
Wildcard DNS
    |
    v
MetalLB fixed IP
    |
    v
Envoy Gateway (3 proxies)
    |
    +--> standard HTTPRoute routing
    +--> TLS, CORS, limits, and security policies
    +--> Prometheus metrics, access logs, and OTLP traces
    |
    v
Application Services
```

Initial policy placement:

| Concern | Placement |
|---|---|
| TLS termination and redirects | Gateway/listeners and HTTPRoute |
| Host/path routing | HTTPRoute |
| Regex rewrites | Envoy Gateway extension policy |
| Basic Auth and external auth | Envoy security policy |
| JWT pre-validation | Envoy where possible; application remains authoritative |
| GraphQL roles and subscription authentication | Application |
| GraphQL complexity | Application |
| Initial rate limiting | Local Envoy policy |
| Exact shared quotas | Global rate-limit service and Redis, if justified |

## Migration Without DNS Changes

The new gateway takes the existing fixed IP and forwards all unmigrated traffic
to ingress-nginx.

```text
Wildcard DNS
    |
    v
Original MetalLB IP
    |
    v
Envoy Gateway
    |
    +--> specific HTTPRoute --> migrated Service
    |
    `--> catch-all HTTPRoute --> ingress-nginx --> legacy Service
```

Specific hostname routes take precedence over the hostname-less catch-all.
The catch-all references the ingress-nginx Service through a `ReferenceGrant`.

### Migration Sequence

1. Deploy Gateway API and Envoy Gateway on a secondary MetalLB IP.
2. Configure TLS and the catch-all route to ingress-nginx.
3. Test with client-side hostname resolution against the secondary IP.
4. Verify redirects, client IPs, WebSockets, large bodies, auth, and tracing.
5. Move ingress-nginx to the secondary IP.
6. Assign the original IP to Envoy Gateway.
7. Add specific HTTPRoutes incrementally; unmatched traffic keeps using NGINX.
8. Migrate Keycloak only after proxy headers, cookies, redirects, and token flows
   are verified.
9. Migrate each oauth2-proxy route together with its protected application.
10. Remove the catch-all and ingress-nginx after fallback traffic reaches zero.

The MetalLB IP handover is not atomic. Plan a short maintenance window and a
tested reverse handover.

## Fallback Safety Requirements

### TLS

Envoy terminates TLS for migrated and fallback traffic. Before IP handover:

- inventory certificate and SAN coverage;
- confirm wildcard coverage for every hostname level;
- confirm listener certificate limits and cross-namespace references;
- preserve the existing external hostname and issuer for Keycloak.

### Forwarded Headers

The fallback hop is HTTP unless backend TLS is explicitly configured.
ingress-nginx must trust forwarded headers only from the Envoy proxy network:

```text
use-forwarded-headers: true
proxy-real-ip-cidr: <exact trusted proxy CIDR>
```

Do not use `0.0.0.0/0`. Incorrect trust can spoof client identity; missing trust
can create HTTPS redirect loops.

### WebSockets

- Preserve `Host`, `Upgrade`, `Connection`, and `graphql-transport-ws`.
- Configure long or disabled idle timeouts for subscriptions.
- Keep both paths available while old connections drain.
- Do not retry GraphQL mutations automatically.

### Observability

Fallback requests cross two proxies and may be counted twice.

```text
Client --> Envoy span --> NGINX span --> Application span
```

- propagate `traceparent` and request IDs;
- identify direct and fallback traffic in metrics and logs;
- apply rate limiting and retries at only one proxy layer;
- use fallback request volume as the retirement signal for NGINX.

## Decision Gates

Implementation should not begin until all of these pass:

- ☐ Gateway API and controller version compatibility is pinned.
- ☐ TLS coverage is complete.
- ☐ The fallback preserves host, scheme, client IP, and WebSockets.
- ☐ No redirect loop occurs on TLS-enabled legacy Ingress resources.
- ☐ Large GraphQL and S3 requests pass configured limits.
- ☐ Keycloak issuer, callbacks, cookies, and token refresh remain unchanged.
- ☐ Three proxy replicas fit the selected resource budget under route load.
- ☐ The MetalLB IP handover and rollback are rehearsed.

## References

- [ingress-nginx retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Gateway API implementations](https://gateway-api.sigs.k8s.io/docs/implementations/list/)
- [Gateway API HTTPRoute](https://gateway-api.sigs.k8s.io/reference/api-types/httproute/)
- [Envoy Gateway security](https://gateway.envoyproxy.io/docs/tasks/security/)
- [Envoy Gateway observability](https://gateway.envoyproxy.io/docs/tasks/observability/)
- [Envoy Gateway regex rewrites](https://gateway.envoyproxy.io/docs/tasks/traffic/http-urlrewrite/)
- [Traefik Gateway API](https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/gateway-api/)
- [APISIX Gateway API support](https://apisix.apache.org/docs/ingress-controller/concepts/gateway-api/)
- [APISIX GraphQL depth limiting](https://apisix.apache.org/docs/apisix/plugins/graphql-limit-count/)
- [ingress-nginx forwarded headers](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/)
