# GitOps

GitOps repository for managing Kubernetes deployments via ArgoCD. All changes to production and dev environments are made through this repo.

## Repository Structure

```
.
├── argocd/                          # ArgoCD Application and ApplicationSet definitions
│   ├── dev/                         # Dev environment apps
│   │   ├── app-of-apps/             # Root Application that discovers all dev apps
│   │   ├── ra/                      # Reviews & Allocations apps
│   │   ├── shared/                  # Shared services (health-check-service, user-office-core-factory, argo-workflows)
│   │   │   └── argo-workflows/      # Argo Workflows install ApplicationSet                  <!-- NEW -->
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
│   │   ├── alloy-config-management-{dev, infra, prod}/
│   │   ├── argo-workflows/          # Argo Workflows install (upstream Helm chart; values only)
│   │   ├── cert-manager/
│   │   ├── rabbitmq-operators/
│   │   └── vault-config-management-{dev, prod}/
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
│       └── vault-operator-config/  # Per-cluster, per-namespace Vault connection config
│           └── dev/
│               ├── apps/           # VaultConnection, VaultAuth, ServiceAccount + RBAC for `apps`
│               └── cron-jobs/      # Same, for `cron-jobs` (ServiceAccount: cron-jobs-vault-op)
│
└── .github/workflows/
    └── create-release-pr.yaml      # Called by source repos to create deploy PRs
```

## How It Works

### ArgoCD App-of-Apps

Each environment has a root `Application` (app-of-apps) that recursively discovers all `ApplicationSet` definitions under its `argocd/{env}/` directory. When you add, modify, or remove an ApplicationSet file, ArgoCD automatically picks it up.

> **Note:** files outside `argocd/{env}/` are not discovered. For dev, the root app (`app-of-apps-dev-ua`) watches `argocd/dev` on `main`, so a new ApplicationSet must live somewhere under `argocd/dev/` (e.g. `argocd/dev/shared/`), not in a new top-level folder such as `argocd/infra/`.

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

Components installed from an **upstream** Helm chart keep only their values (our custom configuration, values.yaml) here in this repo while the chart repository and version are pinned in the ApplicationSet.
<br>`argo-workflows` is the current example:

```
components/infra/argo-workflows/
└── base/
    └── values.yaml        # Helm values for the upstream argo-workflows chart
```

> The CI check runs `kustomize build` on every `components/*/*/overlays/dev`, so a folder named `overlays/dev` must contain a `kustomization.yaml`. Don't put Helm values files in `overlays/` unless the component is built with Kustomize.

### Multi-Cluster Deployment

ApplicationSets use a list generator to target clusters by name. Each app has the fallback cluster commented out by default:

```yaml
generators:
- list:
    elements:
      - name: prod-v5
      #- name: prod-fallback
```

The `vault-operator-config` ApplicationSet is the exception: it uses a matrix generator (cluster × namespace), because a `VaultConnection` and `VaultAuth` must exist in every namespace that consumes Vault secrets:

```yaml
generators:
- matrix:
    generators:
    - list:
        elements:
          - name: dev-v3
            path: dev

    - list:
        elements:
          - namespace: apps
          - namespace: cron-jobs
```

This produces one Application per cluster/namespace pair, <br>named `{{.name}}-{{.namespace}}-vault-operator-config`, <br>sourced from `components/ua/vault-operator-config/{{.path}}/{{.namespace}}` <br>and deployed into `{{.namespace}}`. If you enable the fallback cluster, <br>the matching `{{.path}}/apps` and `{{.path}}/cron-jobs` directories must exist first, otherwise the Application will fail to sync.

See [moving UA apps to the fallback cluster](https://github.com/isisbusapps/ISISBusApps/wiki/Moving-UA-apps-to-the-fallback-cluster) for details.

### Argo Workflows

The Argo Workflows **platform** (controller and server) is installed from this repo. The **jobs** that run on it are not.

| Lives in | What | Deployed by |
|----------|------|-------------|
| This repo | `argocd/dev/shared/argo-workflows/argo-workflows-install.yaml` (ApplicationSet) <br> `components/infra/argo-workflows/base/values.yaml` | `<cluster>-argo-workflows-install` (Helm chart `argo-workflows` from argo-helm, into namespace `argo`) |
| `docker-orchestration` | CronWorkflows <br> workflow templates <br> workflow RBAC <br> VaultStaticSecrets for jobs | `cron-orchestration-dev` ApplicationSet (into namespace `cron-jobs`) |

Points to keep in mind:

- **Don't rename the ApplicationSet or its generated Applications.** ArgoCD uses the Application name (`dev-v3-argo-workflows-install`) as the Helm release name, and every chart resource name is derived from it. Renaming it would deploy a second copy of Argo Workflows instead of updating the running one.
- **`preserveResourcesOnDeletion: true`** is set on the ApplicationSet, so deleting it never removes the running install.
- The controller runs in `argo` and only manages workflows in `cron-jobs` (`controller.workflowNamespaces`).
- Job secrets in `cron-jobs` should reference the `cron-jobs` `VaultAuth` (see [Secrets](#secrets)), not the one in `apps`.

### Clusters

| Environment | Primary | Fallback |
|-------------|---------|----------|
| Prod | `prod-v5` | `prod-fallback` |
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

Each namespace that uses Vault needs its own `VaultConnection` and `VaultAuth` (`static-auth`), 
<br>defined in `components/ua/vault-operator-config/{env}/{namespace}/`. 
<br>A `VaultStaticSecret` must live in the same namespace as the `VaultAuth` it references. Each `VaultAuth` authenticates with a ServiceAccount in its own namespace, created alongside it in `vault-auth-service-account.yaml` together with the RBAC it needs (including a `system:auth-delegator` ClusterRoleBinding):

| Namespace | ServiceAccount | Config directory (dev) |
|-----------|----------------|------------------------|
| `apps` | `vault-op` | `vault-operator-config/dev/apps/` |
| `cron-jobs` | `cron-jobs-vault-op` | `vault-operator-config/dev/cron-jobs/` |

> **Note:** the per-namespace layout (`apps/`, `cron-jobs/`) currently applies to `dev` only. `prod` still uses a single flat `vault-operator-config/prod/` directory deployed into `apps`.

The `VaultAuth` uses the `cluster` Kubernetes auth role on the `submissions` mount. That role is configured in Vault, not in this repo, and its `bound_service_account_names` and `bound_service_account_namespaces` must include each ServiceAccount and namespace above.

The Vault operator and its per-cluster, per-namespace config (`vault-operator-config/`) are deployed at sync-wave `-10` and `-1` respectively, before any application workloads.

### Adding Vault access for a new namespace

1. Copy `components/ua/vault-operator-config/dev/cron-jobs/` to `.../dev/{namespace}/` and update the namespace and ServiceAccount name in all three files. Keep the ServiceAccount name identical across the `ServiceAccount`, the `RoleBinding` and `ClusterRoleBinding` subjects, and the `VaultAuth`.
2. Add `- namespace: {namespace}` to the second list in `argocd/dev/ua/vault-operator-configs/app.yaml`.
3. Add the new ServiceAccount name and namespace to the bound lists of the Vault auth role.

## How Deployments Happen

### Dev

Automatic. Source repos push to `main` (or the version branch), which triggers a GitHub Actions workflow that:
1. Builds the container image
2. Pushes to GHCR
3. Updates the `patch-image.yml` in the dev overlay directly on `main` of this repo
4. ArgoCD syncs the change

Infrastructure components without an image (e.g. `argo-workflows`) are changed by a normal PR to `main`.

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
| -1 | Vault Operator Config (per namespace. e.g. `apps`, `cron-jobs`), UA Shared Config |
| 0 | All application workloads |
| 1 | Health Check Service (dev only) |