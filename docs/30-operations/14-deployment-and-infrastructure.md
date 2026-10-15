# 14 — Deployment and infrastructure

**Status:** Draft
**Owner:** Founding team
**Last updated:** 2026-10-15

How the two planes of doc 03 are deployed, connected, secured, upgraded, backed up, and paid for. The control plane is one Phoenix release per region on Steward's Kubernetes with a managed Postgres; the data plane is one Helm release per customer on the customer's Kubernetes, surrounded by resources a Terraform module provisions. This document fixes the M0 topology (AWS only, two control-plane regions), the pod shape and sizing of the data plane from the numbers in docs 04, 05, 08, and 09, the trust boundary as network rules, the enrolment flow that gives a data plane its identity, the compatibility rules for upgrades, and RPO/RTO per component. It does not restate the lifecycle (doc 13), the wire contract (doc 10), or what may cross the boundary (doc 15); it says where each thing runs and what keeps it running.

## 1. Topology

| | Control plane | Data plane |
|---|---|---|
| Runs on | Steward's EKS, one cluster per region | Customer's Kubernetes (EKS in M0), one Helm release per data plane |
| Regions, M0 | `us-east-1` and `eu-west-1`; an org is pinned to one region at creation and never moves in M0 | One per customer; the customer's targets' region. Multi-region for one customer is deferred (doc 03 §11): a customer whose targets span regions installs two data planes, each with its own identity |
| Provisioned by | Terraform in `deploy/terraform/control-plane/`, applied by Steward's CI | `deploy/terraform/data-plane-aws/` (customer runs it) then `deploy/helm/steward-dataplane/` |
| Clouds | AWS only | **Decision: AWS only in M0, GCP in M1, Azure later.** |

The AWS-only decision is about the Terraform surface, not the code. The `object_store` crate (doc 05 §3.2) already speaks S3, GCS, and Azure Blob, and the adapters (doc 08) do not care where they run. What doubles per cloud is everything around the pods: KMS versus CMEK key policies (doc 09 §8), Secrets Manager versus Secret Manager watchers (doc 08 §5.5), IAM versus Workload Identity for the bucket role, the Neon pageserver's remote storage configuration, and a conformance run of the whole install on a second cloud. Doc 01 §2's first-customer profile (Postgres, Snowflake, Salesforce; 50–5,000 employees) is overwhelmingly on AWS; GCP arrives with BigQuery in M1 (doc 08 §12).

Terraform module interface, data plane (inputs and outputs that the chart consumes):

| Input | Default | Purpose |
|---|---|---|
| `data_plane_id` | required | From `POST /v1/data-planes` (§6); names every resource |
| `kubernetes_cluster` | required | Existing EKS cluster; the module **may** create one with `create_cluster = true` |
| `object_store_bucket_name` | `steward-<data_plane_id>` | One bucket, prefix `steward/` (doc 12 §8.1); versioning on; lifecycle rules in §8 |
| `kms_key_arn` | module creates one | Customer-managed key for SSE-KMS on the bucket (doc 09 §8) |
| `overlay_retention_days`, `compensation_retention_days` | 7, 90 | Lifecycle rule ceilings only; the real clock is the control plane's (doc 13 §9) |
| `target_secret_arns` | `[]` | Existing Secrets Manager secrets the adapter role may read; the module creates the rest |
| `control_plane_region` | required | `us-east-1` or `eu-west-1`; sets the egress allowlist hostname |
| `ingress_scheme`, `allowed_cidrs` | `internal`, `[]` | §4 |
| `neon_mode` | `replica` | `replica` (Neon storage fed by logical replication, doc 08 §11) or `pinned_replica` (the LSN-pinned physical replica fallback) |
| `node_group` | module creates one | Memory-optimised node group (§2) |
| Output | | |
| `irsa_role_arns` | | Three IAM roles (proxy, engine, adapters) for the chart's service accounts |
| `bucket`, `kms_key_arn`, `secret_arns`, `nlb_dns_name` | | Copied into `values.yaml` |

The module provisions: the bucket with lifecycle and a deny on `PutObject` over an existing `*/header.json` (doc 09 §8), the KMS key and its policy, three IRSA roles with least privilege (the adapter role reads target secrets and nothing in the bucket; the engine role has `Get/Put/DeleteObject` on `steward/` and nothing else; the proxy role has `PutObject` on `steward/targets/*/overlays/*` only), the data-plane identity and export-key secrets (empty until enrolment), security groups and the NLB, VPC endpoints for S3 and Secrets Manager so egress never traverses the internet, the node group, and the Neon storage resources for `neon_mode`.

## 2. Data-plane workloads

**Decision: one StatefulSet, `steward-dataplane`, `replicas: 1`, three containers in the pod.** Doc 05 §5.1 places proxy, engine, and adapter host in one pod; doc 08 §12 recommends the adapter host as a sidecar until a data plane has more than ~20 targets; this document makes both binding for M0. The pod is a StatefulSet rather than a Deployment because three things in it tolerate exactly one writer: the routing store SQLite (doc 04 §4), `compensation.db` (doc 09 §4), and the one `Session` stream per data-plane identity (doc 10 §5). A second replica would be a second identity. Doc 04 §6's "scale proxy replicas" is therefore M1 work (§11) and is recorded in §12.

| Container | Image | Requests | Limits | Source of numbers |
|---|---|---|---|---|
| `steward-proxy` | `ghcr.io/steward/proxy` | 1 vCPU, 4 GiB | 2 vCPU, 4 GiB | doc 04 §7: 2 vCPU / 4 GB envelope for 1,000 connections and 5,000 routed branches; its DuckDB `memory_limit = 512 MiB` (doc 05 §5.5) is inside the 4 GiB |
| `steward-engine` | `ghcr.io/steward/engine` | 4 vCPU, 16 GiB | 6 vCPU, 16 GiB | doc 05 §7: 16 GiB cgroup; DuckDB 8 GiB compute + 2 × 2 GiB sandboxes; `threads = min(8, vCPUs − 2)` |
| `steward-adapters` | `ghcr.io/steward/adapters` | 0.5 vCPU, 1.5 GiB | 1 vCPU, 2.5 GiB | doc 08 §7: `-Xmx1g` (`-Xmx2g` above 20 targets), ZGC, CDS; limit leaves 0.5 GiB for metaspace and off-heap gRPC buffers |

The containers share an `emptyDir` at `/run/steward` for the three Unix domain sockets (`engine.sock`, `adapter.sock`, `proxy-facts.sock`), with socket file modes restricted to the three container UIDs (doc 08 §8). They share two volumes:

| Volume | Class | Default size | Holds | Loss means |
|---|---|---|---|---|
| `data` (PVC) | `gp3`, 3,000 IOPS / 125 MB/s (small) or 6,000 / 250 (medium) | 200 GiB | `wal/` (overlay WAL per branch, doc 12 §8.2), `routing/routing.db` (doc 12 §8.6), `evidence/` (doc 12 §8.8), `compensation/compensation.db` (doc 12 §8.7) | §8 runbook: acknowledged-but-unrolled writes are gone |
| `scratch` | Node-local NVMe (`r6id` family) via the local-volume provisioner; `gp3` fallback | 120 GiB | Segment cache 10 GiB, row deltas 50 GiB, DuckDB `temp_directory` 40 GiB (doc 05 §7), CDS archive | Nothing durable; recomputed (doc 05 §4) |

Node affinity: the StatefulSet requires `steward.dev/node-class=dataplane` and the Terraform node group is memory-optimised (`r6id.xlarge`, 4 vCPU / 32 GiB, for small; `r6id.2xlarge`, 8 vCPU / 64 GiB, for medium) because the engine's 16 GiB limit plus the proxy and JVM is ~22 GiB of requests and doc 05 §7's throughput targets assume 8 vCPU / 32 GiB with local NVMe. A `PodDisruptionBudget` with `maxUnavailable: 0` protects the single pod from voluntary eviction; node drains for upgrades therefore require the operator to cordon and let the customer-triggered Helm upgrade (§7) move it, which is deliberate: an unplanned restart aborts open transactions (doc 04 §6) and is recovered in < 5 s, but a planned one should happen at a chosen time.

**HPA: none in M0.** Doc 04's scale signal (`proxy_connections`) and doc 05's (`engine_queue_depth`) are alert thresholds instead (connections > 800 sustained 10 min; queue depth > 2 for 15 min), with the response being a larger node class, not more pods. The M1 split that makes an HPA possible is in §11.

**Neon substrate** (doc 08 §11, `neon_mode = replica`): a sub-chart `steward-neon` runs `neon-storage-broker` (Deployment, 1), `neon-safekeeper` (StatefulSet, 3, 50 GiB `gp3` each), `neon-pageserver` (StatefulSet, 1, 200 GiB `gp3` plus the bucket prefix `steward/neon/` as remote storage), and `neon-replica` (one compute pod on the main timeline, the logical-replication subscriber of the customer's primary). Per-branch compute endpoints are pods the adapter host creates from a template through the Kubernetes API on `openSnapshot` and deletes on `closeSnapshot`, capped at `neon.maxComputes` (default 20); above the cap `openSnapshot` returns `POOL_EXHAUSTED`. The adapter host therefore holds a namespaced Role for `pods` and `services` create/delete, which is the only Kubernetes API access any data-plane component has. For `pinned_replica`, the sub-chart runs the single physical replica instead; its limitations are doc 08 §11's.

### 2.1 Helm values skeleton

Doc 10 §4.1's `TargetSettings` (`branch_ttl_s`, `held_ttl_s`, `overlay_retention_days`, `compensation_retention_days`, `assertion_budget_s`, `summary_values_allowed`, `legal_hold`) and doc 05 §5.3–5.4's per-statement timeouts are **control-plane data, not Helm values**: they are set through the API, delivered on the `Session` stream, and the data plane never derives them locally (doc 13 §9). This answers doc 12's open question (per-kind defaults are a control-plane table, `target_kind_defaults`, not chart values) and doc 05 §12's (memory and thread caps are per data plane and live here; timeouts are per target and live there). The chart carries only what the data plane must know before it has a stream.

```yaml
# deploy/helm/steward-dataplane/values.yaml (skeleton; every key has a schema in values.schema.json)
dataPlaneId: ""                    # from POST /v1/data-planes
controlPlane:
  endpoint: grpc.us-east-1.steward.dev:443   # the one egress hostname (doc 10 §5)
  reconnectBackoff: { initial: 1s, max: 60s }   # doc 10 §5
  heartbeat: { interval: 30s, jitter: 0.2, startupSpread: 30s }   # doc 13 §6.8, doc 07 §5.3
enrolment:
  tokenSecretRef: steward/enrolment-token       # consumed once (§6)
identity:
  certSecretRef: steward/data-plane-identity   # mTLS client cert + key, written at enrolment
  exportKeySecretRef: steward/export-signing-key   # Ed25519 (doc 09 §3.2)
objectStore:
  bucket: ""
  prefix: steward/                   # doc 12 §8.1
  kmsKeyArn: ""
  region: us-east-1
  concurrency: { gets: 16, puts: 4, rangeBytes: 8Mi }   # doc 05 §7
proxy:
  listen: { port: 5432, tls: { secretRef: steward/proxy-server-tls, requireClientCert: false } }  # doc 04 §8
  maxConnections: 1000               # doc 04 §7
  transactionBuffer: { maxBytes: 64Mi, maxRows: 1000000 }   # SD008, doc 04 §7
  mergedRead: { maxRows: 1000000, maxBytes: 512Mi }        # SD009, doc 04 §7
  branchMemoryCeiling: 256Mi         # doc 04 §7
  duckdb: { memoryLimit: 512Mi, threads: 2 }               # doc 05 §5.5
  overlayRoll: { ops: 10000, bytes: 16Mi, idle: 2s }       # doc 05 §4.1
  rollLagAlert: 15m                  # doc 04 §6
  evidence: { fsyncBatch: 100, maxRationaleBytes: 4096 }   # doc 04 §5.5
  resources: { requests: { cpu: 1, memory: 4Gi }, limits: { cpu: 2, memory: 4Gi } }
engine:
  memoryLimit: 16Gi                  # cgroup, doc 05 §7
  duckdb:
    compute: { memoryLimit: 8Gi, threadsMax: 8 }
    sandbox: { memoryLimit: 2Gi, threads: 2 }
    tempDir: { path: /scratch/duckdb, maxBytes: 40Gi }
  concurrency: { computations: 2 }   # doc 05 §7
  segmentCache: { path: /scratch/cache, maxBytes: 10Gi }
  rowDeltaStore: { path: /scratch/changesets, maxBytes: 50Gi }
  compaction: { maxSegments: 64, netBytesMultiple: 4, oldSegmentGrace: 10m, lagAlert: 10m }  # doc 05 §4.2, §7
  freezeMarkerPoll: { every: 2s, timeout: 120s }           # doc 05 §5.2
  adapterBatchTimeout: { postgres: 60s, iceberg: 60s, crm: 300s }   # doc 05 §6
  baseScanRowCap: 10000000           # impact_scan_too_large, doc 05 §5.2
  compensation:
    segmentBytes: 64Mi               # doc 09 §5.2
    gcInterval: 10m                  # doc 09 §5.5
    indexRepairInterval: 1h          # doc 09 §5.4
    orphanGraceDays: 7               # doc 13 §9
    diskAlertPercent: 80             # doc 09 §6
  grantEndpoint:
    port: 8443
    tls: { secretRef: steward/grant-server-tls }
    allowedOrigins: [ https://app.us-east-1.steward.dev ]   # CORS for the browser fetch (§4)
  resources: { requests: { cpu: 4, memory: 16Gi }, limits: { cpu: 6, memory: 16Gi } }
adapters:
  jvm: { xmx: 1g, gc: ZGC }          # doc 08 §7; 2g above 20 targets
  registry:                          # explicit registry, doc 08 §11
    - { kind: postgres, jar: postgres-adapter.jar, class: steward.adapter.postgres.PostgresConnector, version: "" }
  pools: { postgres: 10, snowflake: 4, salesforceHttp: 10 }   # doc 08 §7
  secretWatch: { awsPollInterval: 60s, drainOld: 30s }        # doc 08 §5.5
  connectTimeout: 3s
  statementTimeout: 60s
  resources: { requests: { cpu: 500m, memory: 1536Mi }, limits: { cpu: 1, memory: 2560Mi } }
neon:
  mode: replica                      # replica | pinned_replica
  maxComputes: 20
  pageserver: { storage: 200Gi, resources: { requests: { cpu: 2, memory: 8Gi } } }
  safekeepers: { replicas: 3, storage: 50Gi }
  computeTemplate: { resources: { requests: { cpu: 500m, memory: 1Gi } }, idleSuspend: 5m }
volumes:
  data: { storageClass: gp3, size: 200Gi, iops: 3000, throughput: 125 }
  scratch: { storageClass: local-nvme, size: 120Gi }
ingress:
  scheme: internal                   # internal | internet-facing
  allowedCidrs: []
  listeners: { pgwire: 5432, grant: 8443 }
egress:
  extraCidrs: []                     # target endpoints outside the VPC
nodeSelector: { steward.dev/node-class: dataplane }
observability:
  otlpEndpoint: ""                   # customer's collector; metrics and traces only, no logs with payloads
  traceSampleRatio: 0.01             # doc 04 §9
```

## 3. Control-plane workloads

| Workload | Shape | Sizing | Notes |
|---|---|---|---|
| `steward-control` (Phoenix release: `steward_web`, `steward_coordinator`, `steward_jobs`, `steward_core`; doc 07 §4) | Deployment, 3 replicas per region, PDB `minAvailable: 2`, topology spread across 3 AZs | 2 vCPU / 4 GiB each; doc 07 §4: 100k non-terminal branches ≈ 500 MB per node over three nodes | Readiness gate is the boot sweep (doc 07 §7: ≤ 15 s at 100k); liveness is a BEAM alive check |
| Metadata Postgres | RDS PostgreSQL 16, `db.r6i.xlarge` (4 vCPU / 32 GiB), Multi-AZ synchronous standby, `gp3` 500 GiB at 6,000 IOPS | doc 07 §7's "4 vCPU / 32 GB / NVMe, synchronous replica" | Pools: 20 per node + Oban 10 (doc 07 §7), 3 nodes = 90 + migrator; `max_connections = 200`. **Decision: no read replica in M0.** The queue is a keyset-paginated read model and counters are pre-aggregated (doc 07 §5.5, §5.8), so reads are cheap; a replica would add replication lag to a UI that already says "as of" |
| Analytics export destination | S3 bucket `steward-analytics-<region>`, Parquet per `(org_id, day)` (doc 12 §7), 13-month lifecycle | — | Store choice (ClickHouse vs Parquet) remains open per doc 12; the bucket exists either way because the Parquet files are the ClickHouse load source too |
| gRPC ingress for `Session` | NLB, TCP passthrough on 443 → pod port 50051 | — | §3.1 |
| REST and LiveView ingress | ALB with ACM certificate, `api.<region>.steward.dev` and `app.<region>.steward.dev`, WebSocket idle timeout 3,600 s | — | TLS terminates at the ALB; principals authenticate by API key or session (doc 10 §3), not by certificate |
| Migrations | Kubernetes Job from the same image running `bin/steward eval "Steward.Release.migrate()"` before the rollout | — | Separate `steward_migrator` role, the only one that may drop partitions (doc 07 §8) |

**Decision: BEAM clustering with libcluster `Cluster.Strategy.Kubernetes.DNS`** against a headless Service, cookie from a Secret, EPMD-less distribution on a fixed port with `inet_tls_dist` off inside the cluster (the pod network is private to the namespace by NetworkPolicy). The DNS strategy needs no Kubernetes API permission, which the alternative (`Kubernetes` strategy, list pods) does; `:pg` and the Registry forwarding in doc 07 §4 work over whatever cluster forms. A node that cannot join within 30 s still serves: the Registry is per node and doc 07 §6's duplicate-GenServer rule makes a split brief and harmless.

### 3.1 mTLS termination at the pod

The `Session` stream (doc 10 §5) is authenticated by the client certificate: `data_plane_id` **must** equal the SAN and a mismatch closes the stream; the SAN is also the rate-limit key and the grant `aud` (doc 07 §8). Terminating TLS at a load balancer would reduce that to a header the balancer injects, which any pod would then have to trust, and would turn a one-line identity check into a trust relationship with infrastructure. It would also put an L7 proxy on a stream that stays open for days: ALB idle timeouts cap at 4,000 s and any reconnect is a heartbeat storm (doc 07 §5.3). The NLB forwards TCP, the elixir-grpc Cowboy listener does mTLS with the Steward data-plane CA as the only trusted issuer, and the client sends HTTP/2 keepalive pings every 30 s so the NLB's 350 s idle limit never fires. Cross-zone load balancing is on; a data plane that reconnects lands on any node and doc 07 §4's forwarding handles the rest.

## 4. Networking and the trust boundary

The data plane initiates every connection (doc 10 §5). A Kubernetes `NetworkPolicy` per container plus the Terraform security groups enforce:

| From | To | Allowed | Everything else |
|---|---|---|---|
| `steward-engine` | `grpc.<region>.steward.dev:443` | Yes, the only cross-boundary egress | Denied |
| `steward-engine`, `steward-proxy` | S3 (VPC endpoint), the bucket only | Yes | Denied |
| `steward-adapters` | Target endpoints (`egress.extraCidrs` or the VPC), Secrets Manager (VPC endpoint), Neon services in-namespace, Kubernetes API for compute pods | Yes | Denied; **no route to the control plane** (doc 08 §8) |
| Any data-plane pod | Package registries | Only during image pull, by the node, not the pod | Denied |
| Internet | Any data-plane pod | **No inbound.** The NLB below is the only listener | — |
| Agents (VPC or VPN) | NLB :5432 → `steward-proxy` | Yes, TLS required (doc 04 §8) | — |
| Reviewer's browser | NLB :8443 → `steward-engine` grant endpoint | Yes, grant-authenticated only | — |

**Decision: a dedicated data-plane ingress for the grant endpoint, internal by default, IP allowlisting optional.** The browser's row-delta fetch (doc 07 §5.6, doc 10 §3.3) needs an HTTPS path from the reviewer to the data plane that never touches the control plane. The alternatives were the customer's VPN (works, but makes "open the queue from a laptop" depend on a VPN the RevOps reviewer may not have) or a Steward-hosted relay (rejected: it would proxy row data, doc 13 invariant 9). The engine serves `GET /v1/changesets/{cs}/row-delta`, `.../assertions/{policy_id}/{assertion_id}/samples`, and `.../compensation/{merge_id}` on port 8443 with a server certificate the customer supplies (ACM private CA or their own); every request **must** carry a grant verified against the control plane's ES256 public key (signature, `aud`, `exp`, `cs`, `scope`), and anything else on that port is `404`. CORS allows exactly `https://app.<region>.steward.dev`. `ingress.scheme: internal` places the NLB in private subnets, reachable from the office network or VPN; `internet-facing` plus `allowedCidrs` is for customers without either, and the grant check is the authentication in both cases: an attacker with network reach and no grant gets nothing, and a grant is worth five minutes of one changeset's rows. This answers doc 07 §12 and doc 10 §10: no other gateway is needed.

The pgwire listener shares the NLB (listener 5432) because agents run in the customer's VPC and the proxy's own TLS plus API-key SCRAM (doc 04 §3.1) is the authentication; `requireClientCert: true` enables the optional mTLS of doc 04 §8.

## 5. Secrets and keys

| Secret | Lives in | Holder | Rotation | Overlap |
|---|---|---|---|---|
| Target credentials (`credential_ref` = `aws-sm://…`, doc 08 §5.5) | Customer's Secrets Manager | `steward-adapters` only | Customer rotates; watcher polls every 60 s, drains old pool over 30 s | 30 s |
| Data-plane identity (mTLS client cert + key, SAN = `data_plane_id`) | Secrets Manager `steward/data-plane-identity`, mounted via the Secrets Store CSI driver | `steward-engine` | Issued at enrolment for 90 days; the engine requests renewal at 60 days over the existing stream (`RenewIdentity`, New in `contracts/`); the old cert stays valid until expiry | 30 days |
| Export signing key (Ed25519, doc 09 §3.2) | Secrets Manager `steward/export-signing-key` | `steward-engine` | Generated at enrolment; rotation registers a new public key and the control plane keeps every old public key so earlier manifests still verify | Indefinite for verification |
| Proxy and grant server TLS certs | Customer's choice (ACM PCA or cert-manager) | proxy, engine | cert-manager renews; hot reload on file change | Per issuer |
| Grant signing key (ES256, doc 07 §5.6) | Control plane, AWS KMS asymmetric key per region, signing via KMS so the private key is never in a pod | `steward-control` | Every 90 days; the new public key is pushed to data planes on the stream (`RoutingUpsert`-adjacent `PublicKeys` instruction, New) and both keys are accepted for 24 h (doc 07 §5.6) | 24 h |
| Data-plane CA (issues identity certs) | Control plane, AWS Private CA per region | enrolment service | 5-year root, 1-year intermediate | Standard chain |
| Postgres credentials, Oban, Phoenix `secret_key_base`, OIDC client secrets, release cookie | AWS Secrets Manager, injected as env at pod start | `steward-control` | Postgres via RDS managed rotation every 30 days with a rolling restart | Dual-user rotation |
| Customer-managed KMS key for the bucket (doc 09 §8) | Customer's KMS | S3 on behalf of engine and proxy roles | Customer's policy; annual rotation is the AWS default and is transparent | — |

Nothing in a Secrets Manager entry is ever a Helm value; the chart carries references only. The control plane holds no customer secret of any kind; the data-plane identity's private key is generated in the data plane and only the CSR leaves it (§6).

## 6. Installation and enrolment

```mermaid
sequenceDiagram
    participant Admin as Customer admin
    participant CP as Control plane
    participant TF as terraform apply
    participant Helm as helm install
    participant E as steward-engine
    participant AD as steward-adapters

    Admin->>CP: 1. POST /v1/data-planes {name, region}
    CP-->>Admin: {data_plane_id, enrolment_token (shown once), expires_at = +1h}
    Admin->>TF: 2. apply(data_plane_id, bucket, kms, secrets, roles, NLB, node group, Neon)
    Admin->>Helm: 3. install with values from TF outputs; token in Secret steward/enrolment-token
    E->>E: 4. generate identity keypair + CSR; generate Ed25519 export key
    E->>CP: 5. Enrolment.Enrol{token, csr, export_public_key, versions} (TLS, no client cert)
    CP->>CP: 6. token valid, unused, bound to org+data_plane_id → sign cert, store pubkey, mark used
    CP-->>E: {certificate, ca_chain, grant_public_keys}
    E->>E: 7. write identity to Secrets Manager; delete enrolment Secret
    E->>CP: 8. Session.Connect (mTLS) — stream open; heartbeats begin
    Admin->>CP: 9. POST /v1/targets {kind, credential_ref, data_plane_id}
    CP->>E: 10. Instruction RegisterTarget{target_id, kind, credential_ref}
    E->>AD: resolve credential, construct Connector, describe()
    AD-->>E: TargetDescription
    E-->>CP: InstructionResult{target_description}
    CP-->>Admin: target status: ready ("connected")
```

**Enrolment token.** `stwe_<base64url 32 random bytes>`; the control plane stores `SHA-256(token)`, `org_id`, `data_plane_id`, `expires_at = issued + 1 h`, `used_at`. It is single-use: step 6 is one `UPDATE … SET used_at = now() WHERE hash = ? AND used_at IS NULL AND expires_at > now()` and zero rows is `enrolment_refused`. A used or expired token is replaced by `POST /v1/data-planes/{id}/enrolment-token`, which also revokes any certificate issued under the previous one. Binding is to the org and the `data_plane_id`, not to a target: a data plane serves many targets (doc 08 §12 sizes the host at 20+), and targets are registered afterwards against the `data_plane_id` (doc 10 §4.1 `adapter.data_plane_id`). Steps 1–8 are the `Enrolment` service (`steward.plane.v1.Enrolment`, New) and step 10's `RegisterTarget` instruction is New; both are `contracts/` changes (doc 18 §5) recorded in §12. Until step 10 exists, doc 10 §4.1's "data plane runs `describe()` asynchronously" has no carrier.

Step 5 carries `{chart_version, engine_version, proxy_version, adapters_version, contracts_version}`; §7's compatibility check runs here first, so an incompatible chart fails at install with a clear message rather than at the first heartbeat.

## 7. Upgrades and compatibility

**Control plane: rolling restarts, not hot upgrades.** Phoenix hot code upgrades would avoid the boot sweep, but they need release-handling appups for every GenServer state shape change, are unsupported by Oban's and Ecto's own migration story, and give nothing that a ≤ 15 s boot sweep (doc 07 §7) does not. Deploy order per release: (1) migrations Job (expand phase only, doc 12 §11); (2) rolling update `maxSurge: 1, maxUnavailable: 0`, each new pod ready only after its boot sweep; (3) contract-phase migration in a later release. Continuous deploy from `main` (doc 18 §3) to staging on every merge, to `us-east-1` after the staging suite, to `eu-west-1` 24 h later unless an incident holds it. A data plane sees a control-plane restart as one stream reconnect with jittered backoff (doc 10 §5) and the storm limiter of doc 07 §5.3.

**Data plane: customer-triggered `helm upgrade`.** The chart version is `MAJOR.MINOR.PATCH` and the three images are pinned in the chart; a customer never mixes image versions. The StatefulSet update replaces the one pod; agents see a dropped connection and the SDK reconnects (doc 04 §6, < 5 s). Before the pod stops, a `preStop` hook asks the engine to roll every WAL (so no acknowledged write is only in the WAL during the restart) and to finish in-flight `Persist` calls; the hook has a 60 s budget and the merge worker resumes any apply from `steward.applied_rows` (doc 08 §5.2) afterwards.

| Control plane minor | Accepts data-plane chart minor | Refuses |
|---|---|---|
| `N` | `N`, `N−1` | `< N−1` (too old) and `> N` (newer than the control plane) |

The check is on the `Enrol` call and on every `Session.Connect` (gRPC metadata `steward-dp-version` and `steward-contracts-version`); refusal is `FAILED_PRECONDITION` with the supported range, and the engine logs it, backs off 60 s, and retries, so a customer who upgrades the chart too early sees an alert, not an outage: the proxy keeps serving (doc 13 invariant 15). Within the supported window, every instruction and heartbeat field is additive (doc 10 §2 versioning), the overlay manifest's `version` major is unchanged, and the SQLite `meta.schema_version` migrations embedded in each binary are forward-only. Deprecation: a chart minor is supported for 90 days after `N+2` ships; the control plane emits `data_plane.upgrade_required` events 30 days before refusal.

## 8. Backup and recovery

| Component | Mechanism | RPO | RTO | Notes |
|---|---|---|---|---|
| Metadata Postgres | RDS Multi-AZ synchronous standby; continuous backup with PITR, 35-day window; nightly snapshot copied cross-region | 0 for AZ failure (sync standby); ≤ 5 min for PITR | ≤ 2 min failover; ≤ 60 min PITR restore | PITR is for corruption and operator error, never for AZ loss |
| `events`, `audit_log` | Same, plus the analytics export (doc 12 §7) as a second copy of events | 0 / 5 min | As above | |
| Control-plane pods | Stateless; boot sweep rebuilds process state | 0 | ≤ 15 s per pod | doc 07 §6 |
| Overlay WAL tail (`data` volume) | None beyond the roll: acknowledged writes become durable in the bucket after ≤ 10,000 ops, 16 MiB, 2 s idle, or freeze (doc 05 §4.1) | ≤ 2 s of writes per branch in steady state | — | **This is the exposure.** Volume snapshots do not reduce it (see runbook) |
| Overlay segments, manifests, freeze markers, compensation records | S3 with versioning on; lifecycle: noncurrent versions expire after 30 days; `compensation/*/header.json` never expires; bodies expire by the data plane's GC, not by lifecycle (the lifecycle ceiling is `compensation_retention_days + 30` as a safety net); 99.999999999% durability | 0 | 0 | Versioning plus the deny-overwrite rule is what makes `header.json` immutable (doc 09 §8) |
| Routing store, compensation index, evidence (`data` volume) | Daily EBS snapshot retained 7 days, for forensics; routing rebuilds from `RoutingUpsert` re-sends within ~60 s (doc 04 §6), the index from headers (doc 09 §5.4) | n/a (rebuildable) / 24 h for evidence | ≤ 15 min | Evidence that is lost shows as `evidence_gap` on later changesets |
| `scratch` volume | None | — | Recompute | doc 05 §4 |
| Neon pageserver | Remote storage in the bucket (`steward/neon/`); safekeepers hold unflushed WAL on 3 replicas | 0 | ≤ 10 min to restart from remote storage | A pageserver loss drops open computes: `SNAPSHOT_LOST` for every branch |

**Runbook: data plane lost its `data` volume.** Symptoms: pod cannot mount; or mounts empty. (1) Let the StatefulSet recreate the PVC; the engine starts with empty routing and index files and runs index repair from headers (doc 09 §5.4) and lists `overlays/*/manifest.json` to resume heartbeats for every overlay in the bucket. (2) The control plane, on the first heartbeat batch, applies the following rule, which is new to this document: every branch in `open` on that data plane is moved to `abandoned` with reason `overlay_lost` (New lifecycle reason; doc 12 §3 and doc 13 §2.1 need it), because acknowledged writes in the unrolled WAL tail are gone and the overlay no longer matches what the agent was told; the principal is notified and creates a new branch. (3) A `proposed` branch whose `freeze.json` exists and whose manifest covers `last_seq` is intact (freeze rolls the WAL) and continues; one without a complete roll is also `overlay_lost`. (4) A `merging` branch after its checkpoint has its compensation record in the bucket and its progress in the target's `steward.applied_rows`; apply resumes. (5) `RoutingUpsert` re-sends repopulate the routing store and API keys within ~60 s; agents saw `SD002`/`SD007` meanwhile. Restoring the EBS snapshot first is optional and only recovers evidence; it does not change step 2, because the snapshot predates the lost tail too. `snapshot_lost` is not used here: the base snapshot is intact; it is the overlay that is gone, and reviewers and agents need to be told which.

**Runbook: control plane lost (region).** Data planes keep serving every read and write on `open` branches (doc 13 invariant 15); propose, create, review, and merge start return `503 unavailable` or wait; the engine's stream backs off to 60 s and heartbeats buffer nothing (they are state reports, not events, and the next one carries the current truth). Recovery: (1) promote the cross-region snapshot or PITR-restore in the same region; (2) deploy the release; (3) accept the reconnect storm (token bucket, doc 07 §5.3); (4) watch the heartbeat matrix: any transition committed between the restore point and the outage shows as an `alert` cell (`believed: merging` vs `authoritative: proposed` is the dangerous one, because the data plane may hold a persisted compensation record for a merge row that no longer exists) and is resolved by an operator per doc 13 §6.8, never auto-repaired. The 5-minute RPO bounds how many such cells exist; the synchronous standby is why a region-internal failure has none.

## 9. Environments

| Environment | What runs | Data | Purpose |
|---|---|---|---|
| Local (`tools/stack up`, doc 18 §8) | Docker Compose: metadata Postgres, sample target Postgres 16, MinIO, proxy, engine, adapter host, control plane; Neon-compatible pageserver container optional (`--neon`) | `tools/fixtures` synthetic | Every component must run here; `tools/e2e` runs against it |
| CI ephemeral | `kind` cluster per PR for the chart (`helm template` + `helm install --dry-run` always; a real install on `deploy/**` changes), Testcontainers for adapters (doc 08 §10), Compose for `tools/e2e` | Synthetic | Chart schema, RBAC, NetworkPolicy assertions, conformance suite |
| Staging | Full control plane in `us-east-1` (`api.staging.steward.dev`) plus one Steward-owned data plane in a separate AWS account installed exactly as a customer would (Terraform + Helm), against a synthetic Postgres target seeded by `tools/fixtures` and a Salesforce scratch org nightly | Synthetic only (doc 18 §7) | Every control-plane deploy passes here first; doc 17's load test runs here against the doc 03 principle 9 write patterns |
| Production | Two regions | Customer metadata; row data never | Change only by the §7 pipeline |

Staging is also where the compatibility matrix is exercised: it permanently runs one data plane at chart `N−1` against control plane `N`.

## 10. Cost model per customer data plane

AWS `us-east-1` on-demand list prices, October 2026, rounded; these are the customer's cloud bill, not Steward's. Steward's own cost of goods is the control plane, roughly $1,900/month per region at the §3 sizing (3 × `m6i.large` ≈ $210, RDS `db.r6i.xlarge` Multi-AZ ≈ $1,100, ALB + NLB ≈ $60, EKS ≈ $73, Private CA $400, S3 and KMS < $50), or about $190 per customer at ten customers per region.

| Line | Small: 1 Postgres target, ≤ 50 open branches, ≤ 100 merges/day | Medium: 5 targets, ≤ 500 open branches, ~1,000 merges/day at 10k rows |
|---|---|---|
| Data-plane node (`r6id.xlarge` / `r6id.2xlarge`) | $220 | $440 |
| Neon storage node (`m6i.xlarge` / `m6i.2xlarge`: pageserver, safekeepers, broker, replica compute) | $140 | $280 |
| Compute-pod node (shares the Neon node / `m6i.2xlarge`) | — | $280 |
| EBS `gp3` (data 200 GiB, pageserver 200 GiB, safekeepers 150 GiB / data 500 GiB, pageserver 1 TiB, safekeepers 150 GiB) | $45 | $135 |
| S3 (overlays at 7 days, compensation ~180 GB at 90 days per doc 09 §7, Neon remote storage, requests) | $10 | $40 |
| NLB + NAT gateway + VPC endpoints | $65 | $110 |
| Secrets Manager + KMS | $5 | $15 |
| EKS control plane (only if the module creates a cluster) | $73 | $73 |
| **Total** | **≈ $490–560** | **≈ $1,300–1,400** |

Two consequences for doc 01 §7. First, the per-changeset price has to clear the infrastructure the customer already pays for: a medium customer reviewing 20% of 1,000 merges a day is ~6,000 metered changesets a month against a ~$1,350 cloud bill, so the meter must obviously buy more than the hosting costs, which is the "human attention saved" argument doc 01 makes. Second, the Neon substrate is roughly half the small customer's bill; `pinned_replica` (one `db.r6g.large` read replica, ≈ $150) is cheaper and worse (doc 08 §11), and the fully hosted alternative in §11 would move the entire line onto Steward's margin.

## 11. Alternatives considered

- **Fully hosted data plane** (Steward runs it in a per-customer account). Lower install friction and one operator. Rejected: doc 03 §10 rejected single-plane SaaS for residency; a Steward-owned account per customer still means Steward holds row data and the customer's target credentials. Offered later, if at all, as "Steward-operated in the customer's account" with the customer owning the account and the KMS key.
- **Data plane as a VM image** (AMI with the three processes under systemd, no Kubernetes). Simpler for customers without a cluster. Rejected for M0: the Neon substrate and per-branch compute pods want a scheduler, and doc 03 §9 chose Helm and Terraform because the buyer's platform team already runs them. The `create_cluster` input covers the no-cluster customer.
- **Agent-based install** (a Steward agent in the VPC that pulls its configuration and provisions resources itself). Fewer steps than Terraform + Helm. Rejected: an agent that provisions IAM roles and KMS keys needs broad permissions the buyer's security team will refuse, and the explicit module is auditable; doc 18 §5 says provisioning cloud resources is an "ask" action for Steward's own agents, and the same applies to the product.
- **HPA with a multi-replica proxy Deployment in M0.** Doc 04 §6 assumes it. Deferred to M1: it needs the proxy's routing store populated per pod from the engine's single stream, the WAL moved to a per-pod volume with the engine reading all of them, and a connection-affinity rule for open transactions. The single-pod StatefulSet meets doc 04 §7's 1,000-connection requirement without it.
- **Terminating mTLS at the NLB or an Envoy gateway.** §3.1.
- **GCP and AWS both in M0.** §1.

## 12. Open questions

| Question | Owner | Needed by |
|---|---|---|
| Confirm the single-pod StatefulSet for M0 and that doc 04 §6's "scale proxy replicas" moves to M1 with the split described in §11 | Proxy lead, Founding team | Before doc 04 is Accepted |
| New `contracts/` items this document needs: `steward.plane.v1.Enrolment` service, `RegisterTarget` and `PublicKeys` instructions, `RenewIdentity`, version metadata on `Session.Connect`, and `POST /v1/data-planes` with its enrolment-token endpoints | Control plane lead | Doc 10 amendment, before M0 |
| New lifecycle reason `overlay_lost` for the volume-loss runbook (§8); doc 12 §3 and doc 13 §2.1 need it | Control plane lead | Doc 12, doc 13 amendment |
| The adapter host creating Neon compute pods through the Kubernetes API (§2): acceptable RBAC for customers, or should a small operator own it? | Adapters lead, Infrastructure lead | Before M0 Neon install |
| Per-branch compute cost under the Neon `replica` mode is the largest line for small customers; is `idleSuspend` enough, or does M0 need a shared compute with timeline switching? | Infrastructure lead | After the first staging cost report |
| Multi-region data planes for one customer: confirmed as two data planes with two identities (§1) rather than one identity spanning regions | Founding team | Doc 15 |
| `target_kind_defaults` as a control-plane table (§2.1) rather than Helm values; confirms doc 12's open question and doc 13 §12's TTL-by-kind question | Founding team | Doc 12 amendment |
| GCP module scope for M1: reuse the AWS module shape with Workload Identity and CMEK, or a separate module per cloud | Infrastructure lead | Doc 19 |
| Does the customer-facing `pinned_replica` mode belong in the M0 chart or only in docs until a customer needs it | Adapters lead | Doc 19 |
