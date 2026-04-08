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

## Files

| File | Description |
|---|---|
| `gatewayclass.yaml` | Defines the `envoy-gateway` GatewayClass pointing to the Envoy Gateway controller |
| `reference-grant.yaml` | Grants cross-namespace access from the Gateway to TLS secrets in `apps` |
| `gateway.yaml` | The Gateway resource with HTTP→HTTPS redirect and two HTTPS listeners |

## Installation

Envoy Gateway was installed via Helm:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.7.1 -n envoy-gateway-system --create-namespace
```

Then the manifests were applied:

```bash
kubectl apply -f gatewayclass.yaml -f reference-grant.yaml -f gateway.yaml
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

# Envoy proxy pods running
kubectl get pods -n envoy-gateway-system
# envoy-envoy-gateway-system-envoy-gateway-...   2/2   Running
# envoy-gateway-...                               1/1   Running

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

## Fallback VM Environment

When deploying this identical stack to a cluster without an external Load Balancer provider (like the single-VM `dev-fallback` cluster), Envoy Gateway will create the proxy service but the `EXTERNAL-IP` will remain `<pending>`. 

Instead of routing traffic through standard 80/443 ports, Kubernetes allocates **NodePorts** for the Proxy service. This allows it to run entirely in parallel with the nginx DaemonSet (which uses HostPort 80/443 natively) without any port conflicts.

To determine the automatically assigned NodePorts:
```bash
kubectl get svc -n envoy-gateway-system
# Example Port Spec: 80:30138/TCP, 443:32696/TCP
```

To test routes like `visits-httproute.yaml` in this environment, explicitly resolve the hostname to the VM IP and target the NodePort:

```bash
# Ensure you use curl.exe in PowerShell to avoid the Invoke-WebRequest alias
curl.exe -I -k --resolve test.developers.facilities.rl.ac.uk:<HTTPS_NODEPORT>:<VM_IP> https://test.developers.facilities.rl.ac.uk:<HTTPS_NODEPORT>/visits-alpha
```

## Uninstalling

To remove Envoy Gateway completely:

```bash
kubectl delete -f gateway.yaml -f reference-grant.yaml -f gatewayclass.yaml
helm uninstall eg -n envoy-gateway-system
kubectl delete namespace envoy-gateway-system
```
