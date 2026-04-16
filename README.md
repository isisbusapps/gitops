# GitOps

GitOps repository for managing Kubernetes deployments via ArgoCD. All changes to production and dev environments are made through this repo.

## Repository Structure

```
.
├── argocd/                          # ArgoCD Application and ApplicationSet definitions
│   ├── dev/                         # Dev environment apps
│   │   ├── app-of-apps/             # Root Application that discovers all dev apps
│   │   ├── ra/                      # Reviews & Allocations apps
│   │   ├── shared/                  # Shared services (health-check-service)
│   │   └── ua/                      # Users & Auth apps
│   ├── prod/                        # Production environment apps
│   │   ├── app-of-apps/             # Root Application that discovers all prod apps
│   │   ├── ra/
│   │   └── ua/
│   ├── management-dev/              # Management cluster (dev) - Alloy, Vault
│   └── management-prod/             # Management cluster (prod) - Alloy, Vault
│
├── components/                      # Kubernetes manifests (Kustomize + Helm)
│   ├── infra/                       # Infrastructure components
│   │   ├── alloy-config-management-{dev,prod}/
│   │   ├── cert-manager/
│   │   ├── rabbitmq-operators/
│   │   └── vault-config-management-{dev,prod}/
│   ├── ra/                          # Reviews & Allocations components
│   │   └── approved-experiments/
│   └── ua/                          # Users & Auth components
│       ├── authenticate-frontend/
│       ├── auth-service/
│       ├── establishment-service/
│       ├── mailchimp-webhooks/
│       ├── merge-user-tool/
│       ├── message-broker/          # RabbitMQ (Helm chart)
│       ├── message-broker-secrets/  # RabbitMQ secrets (Helm chart)
│       ├── messages/
│       ├── shared-config/
│       ├── ua-dev-tools/
│       ├── user-establishment-details/
│       ├── user-exchange-client/    # Helm chart
│       ├── user-exchange-client-secret/
│       ├── user-exchange-publisher/
│       ├── user-exchange-topology/  # Helm chart
│       ├── users-v1/               # UOWS REST API v1 (legacy, master-v1 branch)
│       ├── users-v2/               # UOWS REST API v2 (current, main branch)
│       └── vault-operator-config/  # Per-cluster Vault connection config
│
└── .github/workflows/
    └── create-release-pr.yaml      # Called by source repos to create deploy PRs
```

## How It Works

### ArgoCD App-of-Apps

Each environment has a root `Application` (app-of-apps) that recursively discovers all `ApplicationSet` definitions under its `argocd/{env}/` directory. When you add, modify, or remove an ApplicationSet file, ArgoCD automatically picks it up.

### Component Layout

Most components follow the Kustomize base/overlays pattern:

```
components/ua/{service}/
├── base/                  # Shared deployment, service, ingress
│   ├── deployment.yml
│   ├── ingress.yml
│   ├── service.yml
│   └── kustomization.yml
└── overlays/
    ├── dev/               # Dev-specific config, secrets, image
    │   ├── config.yaml
    │   ├── static-secret.yaml
    │   ├── patch-image.yml
    │   └── kustomization.yml
    └── prod/              # Prod-specific config, secrets, image
        ├── config.yaml
        ├── static-secret.yaml
        ├── patch-image.yml
        └── kustomization.yml
```

Some components (message-broker, user-exchange-client, user-exchange-topology) use Helm charts instead of Kustomize.

### Multi-Cluster Deployment

ApplicationSets use a list generator to target clusters by name. Each app has the fallback cluster commented out by default:

```yaml
generators:
- list:
    elements:
      - name: prod-v4
      #- name: prod-fallback
```

See [docs/fallback-cluster-guide.md](docs/fallback-cluster-guide.md) for details.

### Clusters

| Environment | Primary | Fallback |
|-------------|---------|----------|
| Prod | `prod-v4` | `prod-fallback` |
| Dev | `dev-v3` | `dev-microk8s-alternative` |
| Management Prod | `https://kubernetes.default.svc` (local) | - |
| Management Dev | `https://kubernetes.default.svc` (local) | - |

### Secrets

Secrets are managed via HashiCorp Vault using the Vault Secrets Operator. Each app defines a `VaultStaticSecret` resource that syncs secrets from Vault into Kubernetes Secrets:

```yaml
spec:
  mount: users-and-auth
  path: prod/user-office-web-service    # Vault path
  destination:
    name: user-office-web-service-v2    # K8s Secret name
```

The Vault operator and its per-cluster config (`vault-operator-config/`) are deployed at sync-wave `-10` and `-1` respectively, before any application workloads.

## How Deployments Happen

### Dev

Automatic. Source repos push to `main` (or the version branch), which triggers a GitHub Actions workflow that:
1. Builds the container image
2. Pushes to GHCR
3. Updates the `patch-image.yml` in the dev overlay directly on `main` of this repo
4. ArgoCD syncs the change

### Prod

Manual, via PR. Source repos trigger a release workflow that:
1. Builds the container image with a version tag
2. Creates a branch in this repo with the updated `patch-image.yml`
3. Triggers the `create-release-pr.yaml` workflow to open a PR
4. A human reviews and merges the PR
5. ArgoCD syncs the change

See [docs/uows-release-guide.md](docs/uows-release-guide.md) for the UOWS-specific process including how to create new versions.

## Sync Waves

| Wave | Resources |
|------|-----------|
| -10 | Vault Operator (Helm) |
| -1 | Vault Operator Config, UA Shared Config |
| 0 | All application workloads |
| 1 | Health Check Service (dev only) |
