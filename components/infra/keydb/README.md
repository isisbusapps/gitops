# KeyDB Three-Cluster Full Mesh

Multi-Master + Active Replica across three Kubernetes clusters in full mesh replication.


---

## System Overview

Three independent KeyDB clusters (PROXMOX, STFC CLOUD, ISIS VMS), each with a single KeyDB deployment, joined in a **full mesh replication topology** where each cluster replicates from the other two.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    3 KEYDB CLUSTERS IN FULL MESH REPLICATION                                        │
│                                                                                                     │
│     Each Cluster: Single KeyDB Instance (or local HA pair)                                          │
│     Inter-Cluster: Full Mesh Replication (multi-master + active-replica)                            │
│     Recovery: Failed cluster rejoins mesh and syncs from peers                                      │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Replication Topology

```
            ┌─────────────────┐
            │    PROXMOX      │
            │   KeyDB-1       │
            └───────┬─────────┘
                    │
           ╔════════╪════════╗
           ║        │        ║
           ║        │        ║
           ▼        ▼        │
    ┌─────────────┐          │
    │ STFC CLOUD  │◄─────────┤
    │  KeyDB-2    │          │
    └──────┬──────┘          │
           │                 │
           ╲       ╱         │
            ▼     ▼          │
    ┌─────────────┐          │
    │  ISIS VMS   │◄─────────┘
    │  KeyDB-3    │
    └─────────────┘

FULL MESH CONFIGURATION:

PROXMOX KeyDB-1:
  --replicaof keydb-stfc-cloud.apps.svc.cluster.local 6379
  --replicaof keydb-isis-vms.apps.svc.cluster.local 6379

STFC CLOUD KeyDB-2:
  --replicaof keydb-proxmox-vms.apps.svc.cluster.local 6379
  --replicaof keydb-isis-vms.apps.svc.cluster.local 6379

ISIS VMS KeyDB-3:
  --replicaof keydb-proxmox-vms.apps.svc.cluster.local 6379
  --replicaof keydb-stfc-cloud.apps.svc.cluster.local 6379
```

`multi-master yes` and `active-replica yes` are set in `base/configmap.yaml` and apply to all clusters.

### Local Application Access

```
Proxmox Apps ─────► keydb.apps.svc.cluster.local  (Cilium affinity: local)
Cloud Apps   ─────► keydb.apps.svc.cluster.local  (Cilium affinity: local)
ISIS Apps    ─────► keydb.apps.svc.cluster.local  (Cilium affinity: local)

Data written to ANY cluster automatically replicates to ALL clusters.
```

---

## Directory Structure

```
components/infra/keydb/
├── base/
│   ├── configmap.yaml      
│   ├── deployment.yaml          
│   ├── service.yaml            
│   ├── replication-service.yaml 
│   └── kustomization.yaml
├── overlays/
│   ├── proxmox-vms/
│   │   ├── kustomization.yaml
│   │   └── patch-deployment.yaml   # Adds --replicaof stfc-cloud + isis-vms, cluster label
│   ├── stfc-cloud/
│   │   ├── kustomization.yaml
│   │   └── patch-deployment.yaml   # Adds --replicaof proxmox-vms + isis-vms, cluster label
│   └── isis-vms/
│       ├── kustomization.yaml
│       └── patch-deployment.yaml   # Adds --replicaof proxmox-vms + stfc-cloud, cluster label
└── README.md
```

---

## Prerequisites

- kubectl configured with contexts for all three clusters
- Kustomize (included in kubectl v1.14+)
- Cilium ClusterMesh enabled across all three clusters
- **Cilium >= 1.19.3** (see [Troubleshooting](#troubleshooting))

---

## Configuration

All KeyDB settings live in `base/configmap.yaml` — a single config for all clusters. The only per-cluster difference is the `--replicaof` peer addresses, set in each overlay's `patch-deployment.yaml`.


## Monitoring

### Metrics (Prometheus)

Each pod runs a `redis_exporter` sidecar on port 9121. Pod annotations enable automatic scraping:

```
prometheus.io/scrape: "true"
prometheus.io/port:   "9121"
prometheus.io/path:   "/metrics"
```

### Check replication status

```bash
for ctx in proxmox-vms-admin@proxmox-vms stfc-cloud-admin@stfc-cloud isis-vms-admin@isis-vms; do
  echo "=== $ctx ==="
  kubectl --context="$ctx" exec -n apps deploy/keydb -- \
    keydb-cli -a "$KEYDB_PASSWORD" --no-auth-warning INFO replication \
    | grep -E "role:|connected_slaves:|master_link_status:"
done
```
## Data Flow Scenarios

### Normal write operation

```
Application in PROXMOX writes: SET key1 value1

[Proxmox App] → SET key1 value1 → [Proxmox KeyDB-1]
                                        │
                                        ├─────────────┐
                                        │             │
                                        ▼             ▼
                              [STFC CLOUD KeyDB-2]  [ISIS VMS KeyDB-3]

RESULT:
  ✓ All 3 clusters have key1=value1
  ✓ Replication latency: ~2.5–3.5s across datacentres (eventual consistency)
  ✓ Local reads return the value immediately after a local write
```

### Cluster failure and recovery

```
SCENARIO: STFC CLOUD cluster goes down

T+0: STFC CLOUD KeyDB-2 becomes unreachable
T+1-5s: PROXMOX and ISIS detect KeyDB-2 failure (master_link_status: down)

T+0 to T+N:
  PROXMOX and ISIS continue operating
  Replication continues between PROXMOX ↔ ISIS

T+Recovery: STFC CLOUD comes back online
  KeyDB-2 reconnects to PROXMOX and ISIS
  Full sync from peers; full mesh replication restored

RESULT:
  ✓ Zero data loss (writes continued on remaining clusters)
  ✓ Automatic recovery when cluster rejoins
```

---

## Known Issues and Limitations

1. **Data Conflicts During Network Partitions** — `INCR`, `HINCRBY` can cause data loss; KeyDB uses last-write-wins. Use `SET`/`GET` for critical data.
2. **OOM Cascading Failures** — When one cluster crashes, the others absorb all traffic. Mitigated by `maxmemory` + `allkeys-lru`.
3. **Split-Brain** — No leader election; all clusters accept writes during partitions. Document the eventual consistency model for application owners.
4. **Replication Lag** — Cross-datacentre replication latency is ~2.5–3.5s. Do not read from a different cluster immediately after a write and expect fresh data.
5. **Persistent Storage** — Pods currently use `emptyDir`. On pod restart the node starts empty and re-syncs from peers. Use PersistentVolumes if data must survive a pod restart without waiting for full resync.
6. **Secret Management** — `base/secret.yaml` holds a placeholder. Apply real credentials out-of-band (see [Deployment](#deployment)). Consider migrating to Sealed Secrets or External Secrets Operator + Vault for GitOps-safe secret management.

---

## Troubleshooting

### Cross-cluster DNS not resolving peer KeyDB instances

**Symptom:** `--replicaof keydb-proxmox-vms.apps.svc.cluster.local 6379` fails to resolve from a remote cluster.

**Root cause:** CoreDNS only resolves names for `Service` objects that exist **locally** on the cluster. Remote cluster services are only reachable by DNS if their `Service` object exists locally **and** Cilium has synced the remote `EndpointSlice` for it.

**Fix — deploy the replication service to every cluster:**

`base/replication-service.yaml` defines all three headless services (`keydb-isis-vms`, `keydb-proxmox-vms`, `keydb-stfc-cloud`). It is included in the base kustomization and deployed to all three clusters so that:

- The home cluster's service matches its own pods via the `cluster: <name>` pod label selector.
- The remote clusters have a Service object with zero local endpoints, but Cilium injects the synced EndpointSlices so CoreDNS can return the real remote pod IP.

Verify that all three services exist on every cluster:

```bash
for ctx in proxmox-vms-admin@proxmox-vms stfc-cloud-admin@stfc-cloud isis-vms-admin@isis-vms; do
  echo "=== $ctx ==="
  kubectl --context="$ctx" get svc -n apps -l app=keydb
done
```

Expected output per cluster: three services (`keydb-isis-vms`, `keydb-proxmox-vms`, `keydb-stfc-cloud`).

---

### Cilium ClusterMesh — EndpointSlice synchronisation not active

**Symptom:** Remote service DNS resolves but routes to the wrong cluster, or EndpointSlices for peer clusters are missing.

**Root cause:** `clustermesh.enableEndpointSliceSynchronization` is `false` (the default). Cilium must be told to sync EndpointSlices across the mesh.

**Minimum version required: Cilium 1.19.3**

> Cilium v1.19.0–v1.19.2 has a known nil-pointer panic in the operator when `enableEndpointSliceSynchronization` is enabled. Upgrade all clusters to **1.19.3 or later** before proceeding.
> See: https://github.com/cilium/cilium/issues/45396

**Fix — diagnose then enable EndpointSlice synchronisation:**

```bash
CHART_VERSION=$(helm --kube-context <context> history cilium -n kube-system --max 1 -o json \
  | python3 -c "import json,sys; h=json.load(sys.stdin); print(h[0]['chart'].replace('cilium-',''))")

helm upgrade cilium cilium/cilium \
  --kube-context <context> \
  --namespace kube-system \
  --version "${CHART_VERSION}" \
  --reuse-values \
  --set clustermesh.enableEndpointSliceSynchronization=true \
  --wait --timeout 300s
```

**Verify EndpointSlices are being synced:**

```bash
# From proxmox-vms, check that EndpointSlices exist for the isis-vms service
kubectl --context proxmox-vms-admin@proxmox-vms \
  get endpointslices -n apps -l kubernetes.io/service-name=keydb-isis-vms

```

---

### Replication shows `master_link_status:down`

```bash
# Check replication info
kubectl --context <context> exec -n apps deploy/keydb -- \
  keydb-cli -a "$KEYDB_PASSWORD" --no-auth-warning INFO replication

# Check whether peer DNS resolves
kubectl --context <context> exec -n apps deploy/keydb -- \
  getent hosts keydb-proxmox-vms.apps.svc.cluster.local

# Check pod labels match service selectors
kubectl --context <context> get pods -n apps -l app=keydb --show-labels
```

---

## References

- [KeyDB Documentation](https://docs.keydb.dev/)
- [KeyDB Active Replication](https://docs.keydb.dev/docs/replication/)
- [Cilium EndpointSlice Sync](https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/)
- [Cilium issue #45396](https://github.com/cilium/cilium/issues/45396)
