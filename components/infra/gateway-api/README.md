# Envoy Gateway API

Envoy Gateway deployed alongside the existing nginx ingress controller on the Kubernetes cluster. Both run in parallel — nginx continues to serve all existing apps while Envoy Gateway is ready to accept new HTTPRoute resources.

## Architecture

```
                    DNS (wildcard)
         *.facilities.rl.ac.uk
         *.developers.facilities.rl.ac.uk
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
  130.246.81.235          130.246.214.231
  nginx LB                Envoy Gateway LB
  (existing)              (new)
  32 Ingress resources    0 HTTPRoutes (ready)
```

## Components

| Component | Version | Namespace |
|---|---|---|
| Envoy Gateway controller | v1.7.1 | `envoy-gateway-system` |
| Gateway API CRDs | v1.4.1 (bundled) | cluster-scoped |
| GatewayClass | `envoy-gateway` | cluster-scoped |
| Gateway | `envoy-gateway` | `envoy-gateway-system` |
| Envoy Proxy (data plane) | auto-managed | `envoy-gateway-system` |

## Gateway Listeners

| Listener | Port | Protocol | Hostname | Behaviour |
|---|---|---|---|---|
| `http` | 80 | HTTP | all | Redirects to HTTPS |
| `https-facilities` | 443 | HTTPS | `*.facilities.rl.ac.uk` | TLS termination |
| `https-developers` | 443 | HTTPS | `*.developers.facilities.rl.ac.uk` | TLS termination |

All listeners accept HTTPRoutes from **any namespace** (`allowedRoutes.namespaces.from: All`).

## TLS Certificates

The Gateway references existing wildcard TLS secrets from the `apps` namespace via a **ReferenceGrant** (no secret duplication):

| Secret | Namespace | Hostname |
|---|---|---|
| `facilities-tls-certificate` | `apps` | `*.facilities.rl.ac.uk` |
| `developers-tls-certificate` | `apps` | `*.developers.facilities.rl.ac.uk` |

The `ReferenceGrant` in `apps` namespace grants the Gateway in `envoy-gateway-system` permission to read these secrets.

## Directory Structure

The Gateway manifests are structured using Kustomize overlays, allowing you to deploy the same core configuration to both development and production clusters.

```text
gateway-api/
├── base/
│   ├── envoy-proxy-config.yaml  # Configures Envoy data plane as a DaemonSet
│   ├── gateway.yaml             # Gateway resource with HTTPS listeners
│   ├── gatewayclass.yaml        # Defines envoy-gateway GatewayClass
│   ├── https-redirect.yaml      # HTTPRoute that redirects HTTP to HTTPS
│   ├── reference-grant.yaml     # Grants cross-namespace access to TLS secrets
│   └── kustomization.yaml       # Base kustomization definition
└── overlays/
    ├── dev/
    │   └── kustomization.yaml   # Dev-specific overrides
    └── prod/
        └── kustomization.yaml   # Prod-specific overrides
```

## Installation

Envoy Gateway was installed via Helm:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.7.1 -n envoy-gateway-system --create-namespace
```

Then, apply the Gateway resources using the appropriate Kustomize overlay for your cluster:

```bash
# For Development cluster
kubectl apply -k overlays/dev

# For Production cluster
kubectl apply -k overlays/prod
```

## Verification

```bash
# GatewayClass accepted
kubectl get gatewayclass envoy-gateway
# NAME            CONTROLLER                                      ACCEPTED   AGE
# envoy-gateway   gateway.envoyproxy.io/gatewayclass-controller   True       ...

# Gateway programmed with external IP
kubectl get gateway -n envoy-gateway-system
# NAME            CLASS           ADDRESS           PROGRAMMED   AGE
# envoy-gateway   envoy-gateway   130.246.214.231   True         ...

# Envoy proxy pods running (DaemonSet — one per worker node)
kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy -o wide
# envoy-...-2jx26   2/2   Running   ...   dev-v3-default-md-0-sqm5j-cz5ck
# envoy-...-9wf8l   2/2   Running   ...   dev-v3-default-md-0-sqm5j-ksqs5
# envoy-...-fn8g8   2/2   Running   ...   dev-v3-default-md-0-sqm5j-bfkm8

# LoadBalancer with floating IP
kubectl get svc -n envoy-gateway-system
# envoy-envoy-gateway-system-envoy-gateway-...   LoadBalancer   ...   130.246.214.231   80,443
```

## Migrating an App (Next Steps)

To migrate an app from nginx Ingress to Envoy Gateway, create an HTTPRoute. For example, to migrate `messages-service`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: messages-service
  namespace: apps
spec:
  parentRefs:
    - name: envoy-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "*.developers.facilities.rl.ac.uk"
    - "*.facilities.rl.ac.uk"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /messages
      backendRefs:
        - name: messages-service
          port: 30000
```

To test the new route **before** updating your DNS, you can use `curl` with the `--resolve` flag to force the test domain to resolve to the new Envoy Gateway IP (`130.246.214.231`):

```bash
# Test HTTP to HTTPS redirect
curl -I --resolve test.developers.facilities.rl.ac.uk:80:130.246.214.231 http://test.developers.facilities.rl.ac.uk/messages

# Test HTTPS route
curl -I -k --resolve test.developers.facilities.rl.ac.uk:443:130.246.214.231 https://test.developers.facilities.rl.ac.uk/messages
```

If testing via a browser, add an entry to your local `hosts` file (`C:\Windows\System32\drivers\etc\hosts` or `/etc/hosts`):
```text
130.246.214.231 test.developers.facilities.rl.ac.uk
```

Once confirmed working, update your actual DNS to point to the new Envoy Gateway IP (`130.246.214.231`) and remove the old Ingress resource.

## Fallback VM Environment (MicroK8s)

When deploying to a single-node fallback VM without an external Load Balancer provider (like OpenStack Octavia), the Envoy Gateway Service's `EXTERNAL-IP` will remain `<pending>`.

To mimic the behavior of the legacy Nginx Ingress (which natively binds to ports 80 and 443 on the host), we provide a dedicated `dev-fallback` Kustomize overlay. This overlay patches the `EnvoyProxy` configuration to map the host's physical ports directly to the Envoy proxy container.

```bash
# 1. Disable legacy nginx ingress first to free up ports 80 and 443
microk8s disable ingress

# 2. Apply the fallback overlay
kubectl apply -k overlays/dev-fallback
```

### Troubleshooting: Envoy Proxy CrashLoopBackOff on Fallback Cluster

If you attempt to bind Envoy to ports 80/443 by forcing `hostNetwork: true` and `useListenerPortAsContainerPort: true`, the Envoy proxy pod will crash loop with these errors:

1. **`cannot bind '0.0.0.0:19001': Address already in use`**
   MicroK8s runs its internal distributed database (`k8s-dqlite`) on port `19001` on the VM host. If the Envoy proxy pod shares the host network, its default Prometheus stats listener collides with MicroK8s, causing an instant crash.
2. **`cannot bind '0.0.0.0:80': Permission denied`**
   Envoy Gateway forces strict security contexts (e.g., `allowPrivilegeEscalation: false`) and runs Envoy as a non-root user. Even if you try to manually patch `runAsUser: 0` or inject Linux capabilities like `NET_BIND_SERVICE`, the Envoy Gateway controller intercepts and drops those overrides, permanently blocking access to privileged ports (< 1024).

**The Solution (`hostPort` mapping):**
The `dev-fallback` overlay avoids `hostNetwork` entirely. Instead, it relies on standard Kubernetes `hostPort` routing. Envoy runs normally and binds internally to its default unprivileged high ports (`10080` and `10443`). We then use a Kustomize StrategicMerge patch to instruct Kubernetes to forward traffic from the VM's physical `80`/`443` ports into those unprivileged container ports.

```yaml
# Inside overlays/dev-fallback/envoy-proxy-hostnetwork-patch.yaml
spec:
  # Disable Prometheus to avoid any internal conflicts with MicroK8s on port 19001
  telemetry:
    metrics:
      prometheus:
        disable: true
  provider:
    kubernetes:
      envoyDaemonSet:
        patch:
          type: StrategicMerge
          value:
            spec:
              template:
                spec:
                  containers:
                    - name: envoy
                      ports:
                        - containerPort: 10080
                          hostPort: 80
                          protocol: TCP
                        - containerPort: 10443
                          hostPort: 443
                          protocol: TCP
```

## Troubleshooting: Intermittent 5–10 Second Request Delays

### Symptom

Requests to services routed through Envoy Gateway intermittently take 5 or 10 seconds, while the same services respond instantly through the nginx Ingress controller.

```text
Request 1 - Total: 0.489s   ← fast (hit the right node)
Request 2 - Total: 5.459s   ← slow (1 retry)
Request 3 - Total: 0.401s   ← fast
Request 4 - Total: 10.330s  ← slow (2 retries)
Request 5 - Total: 10.560s  ← slow (2 retries)
```

### Root Cause

By default, Envoy Gateway deploys the Envoy proxy as a single-replica **Deployment**. The proxy pod runs on only one of the worker nodes. However, the OpenStack LoadBalancer (Octavia) distributes incoming traffic across **all** worker nodes in a round-robin fashion.

The Envoy proxy service is created with `externalTrafficPolicy: Local`, which means kube-proxy on nodes **without** the Envoy pod will silently drop the traffic rather than forwarding it. When Octavia sends a request to a node without the pod, the connection hangs until the LB's 5-second retry timeout kicks in. If it retries to another empty node, you get a 10-second delay.

With 3 worker nodes and only 1 running the proxy, roughly 2 out of 3 requests would hit an empty node.

### Diagnostic Commands

```bash
# 1. Break down request timing to identify where the delay occurs
curl.exe -o NUL -s -w "DNS: %{time_namelookup}s\nConnect: %{time_connect}s\nTLS: %{time_appconnect}s\nFirstByte: %{time_starttransfer}s\nTotal: %{time_total}s\n" -k https://devkubernetes.developers.facilities.rl.ac.uk/messages

# 2. Run multiple requests to observe the intermittent pattern
for i in $(seq 1 5); do
  curl -o /dev/null -s -w "Request $i - Total: %{time_total}s\n" -k https://devkubernetes.developers.facilities.rl.ac.uk/messages
done

# 3. Check which nodes have the Envoy proxy pod
kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy -o wide

# 4. Verify backend health via the Envoy admin interface
kubectl port-forward -n envoy-gateway-system <envoy-pod> 19000:19000
curl http://localhost:19000/clusters | grep messages
```

### Fix: DaemonSet via EnvoyProxy Resource

The fix is to run the Envoy proxy as a **DaemonSet** so that every worker node has a proxy pod. This ensures that no matter which node the OpenStack LB sends traffic to, there is always a local Envoy pod ready to handle it.

This is configured via two resources:

1. **`envoy-proxy-config.yaml`** — an `EnvoyProxy` custom resource that tells the Envoy Gateway controller to use a DaemonSet:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: envoy-daemonset-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDaemonSet: {}
```

2. **`gatewayclass.yaml`** — updated with a `parametersRef` that links to the EnvoyProxy resource:

```yaml
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: envoy-daemonset-config
    namespace: envoy-gateway-system
```

Once applied, Envoy Gateway automatically replaces the single-replica Deployment with a DaemonSet. The `externalTrafficPolicy: Local` is preserved, which means **real client source IPs are retained** in request headers.

### Results After Fix

```text
Request 1 - Total: 0.532s
Request 2 - Total: 0.496s
Request 3 - Total: 0.512s
Request 4 - Total: 0.744s
Request 5 - Total: 0.366s
```

All requests consistently complete in under 1 second.

## Uninstalling

To remove Envoy Gateway completely:

```bash
# Delete the kustomize overlay resources
kubectl delete -k overlays/prod # or overlays/dev

# Uninstall the Helm chart and namespace
helm uninstall eg -n envoy-gateway-system
kubectl delete namespace envoy-gateway-system
```
