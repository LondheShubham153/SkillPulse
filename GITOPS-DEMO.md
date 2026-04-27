# SkillPulse GitOps Demo (gitops branch)

A second-tier deployment story for the masterclass: same SkillPulse app, but on **EKS + ArgoCD + kube-prometheus-stack**. Lives on the `gitops` branch only — main course (`DEPLOYMENT.md`) is the EC2/SSH path. This is **demo-only**, not taught live.

> Status: **plan**. Phase 1 (k8s-ready images for backend + frontend) is done. Phase 2 (EKS + ArgoCD + Grafana) is what this doc designs — nothing in `terraform-eks/`, `k8s/`, `argocd/`, or `observability/` yet.

---

## 1. Goal

```
git push (gitops branch)
  → ci.yml builds & pushes skillpulse-{backend,frontend} images (matrix)
  → ArgoCD on EKS sees new manifest commits + new image tags
  → ArgoCD reconciles cluster state → new pods roll out
  → Grafana dashboards reflect cluster health automatically
```

The contrast with main:
| | main branch | gitops branch |
|---|---|---|
| Compute | 1 EC2 (t3.medium) | EKS cluster (control plane + 1 node) |
| Deploy mechanism | SSH + `git pull` + `docker compose` | ArgoCD reconciliation loop |
| Frontend delivery | host file mount | Docker image (Phase 1, done) |
| Observability | Backend logs only | Prometheus + Grafana dashboards |
| CI | one job → 1 image | matrix → 2 images |
| CD | `cd.yml` SSH script | (none — ArgoCD pulls from git) |
| Cost while running | ~$33/mo | ~$105/mo |

---

## 2. Architecture

```
                ┌──────────────────────────────────────┐
                │              GitHub                  │
                │  ┌──────────┐    ┌────────────────┐  │
   git push ───►│  │  Repo    │───►│  Actions (CI)  │  │
                │  │  gitops/ │    │  matrix×2 imgs │  │
                │  └──────────┘    └────────────────┘  │
                └──────┬───────────────────┬──────────┘
                       │ manifests          │ images
                       ▼                    ▼
                ┌──────────────────────────────────────┐
                │           Docker Hub                 │
                │  skillpulse-{backend,frontend}       │
                └──────────────────┬───────────────────┘
                                   │ pull
                ┌──────────────────▼───────────────────┐
                │           EKS (us-west-2)            │
                │  ┌─────────┐  ┌──────────────────┐   │
                │  │ ArgoCD  │  │  skillpulse ns   │   │
                │  │ (watch  │─▶│  - frontend Pod  │   │
                │  │ gitops) │  │  - backend Pod   │   │
                │  └─────────┘  │  - mysql StatefulSet │
                │               └──────────────────┘   │
                │  ┌──────────────────────────────┐    │
                │  │  monitoring ns               │    │
                │  │  kube-prometheus-stack       │    │
                │  │  (Prometheus + Grafana)      │    │
                │  └──────────────────────────────┘    │
                └──────────────────────────────────────┘
                          ▲              ▲
                          │              │  kubectl port-forward
                       (instructor laptop, demo time)
```

No ALB, no Ingress. UIs accessed via `kubectl port-forward` during the demo. Saves ~$20/mo and removes the DNS/TLS distraction.

---

## 3. Prerequisites

- Everything from `DEPLOYMENT.md §3` (AWS, Terraform, gh, Docker Hub PAT)
- `kubectl` installed
- `helm` installed (for one-time ArgoCD bootstrap)
- (Optional) `eksctl` if you prefer it over Terraform — we use Terraform

---

## 4. Repo Layout (gitops branch additions)

```
SkillPulse/ (gitops branch)
├── ... existing files (DEPLOYMENT.md, terraform/, .github/, etc.) ...
├── GITOPS-DEMO.md                ← this file
├── frontend/Dockerfile           ← Phase 1 (done)
├── terraform-eks/                ← NEW: EKS infra
│   ├── main.tf                   ← VPC + EKS module + node group
│   ├── variables.tf
│   ├── outputs.tf
│   ├── kubeconfig.tf             ← null_resource to write kubeconfig (optional)
│   └── .gitignore
├── k8s/                          ← NEW: app manifests (raw YAML, no Helm)
│   ├── namespace.yaml
│   ├── mysql/
│   │   ├── deployment.yaml       ← mysql:8.4 + emptyDir (ephemeral, reseeded each pod)
│   │   ├── service.yaml          ← ClusterIP
│   │   ├── configmap-init.yaml   ← init.sql wrapped in ConfigMap
│   │   └── secret.yaml           ← DB user/passwords (demo placeholder values)
│   ├── backend/
│   │   ├── deployment.yaml       ← image: skillpulse-backend:latest, 1 replica
│   │   ├── service.yaml          ← ClusterIP :8080
│   │   └── configmap.yaml        ← non-secret env (DB host, port, name)
│   └── frontend/
│       ├── deployment.yaml       ← image: skillpulse-frontend:latest, 1 replica
│       └── service.yaml          ← ClusterIP :80 (port-forward target)
├── argocd/                       ← NEW: ArgoCD apps (app-of-apps pattern)
│   ├── README.md
│   ├── root-app.yaml             ← syncs the `argocd/apps/` directory
│   └── apps/
│       ├── skillpulse.yaml       ← Application: targets k8s/
│       └── observability.yaml    ← Application: helm install kube-prometheus-stack
└── observability/
    ├── values.yaml               ← kube-prometheus-stack helm values overrides
    └── dashboards/
        └── cluster-overview.json ← imported as ConfigMap with grafana_dashboard label
```

---

## 5. EKS Terraform (terraform-eks/)

**Use the official AWS modules** — DIY-ing EKS in raw HCL is a multi-hundred-line trap.

```hcl
# terraform-eks/main.tf (sketch)

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.95" }   # EKS module v20 caps below v6
  }
}

provider "aws" {
  region = var.region
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "skillpulse-vpc"
  cidr = "10.0.0.0/16"
  azs             = ["us-west-2a", "us-west-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # cost optimization: 1 NAT, not per-AZ
  enable_dns_hostnames = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "skillpulse"
  cluster_version = "1.32"   # latest stable as of 2026-Q1; verify before apply

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true   # so kubectl from instructor laptop works

  eks_managed_node_groups = {
    default = {
      desired_size = 1
      min_size     = 1
      max_size     = 2
      instance_types = ["t3.large"]   # bumped from t3.medium for Prometheus headroom
    }
  }

  enable_irsa = true   # for future workloads needing IAM roles
}
```

**Outputs** include `cluster_endpoint`, `cluster_name`, and AWS commands to write kubeconfig.

**Hidden cost watch:**
- NAT Gateway: ~$32/mo (single-NAT) — biggest non-control-plane cost. Required for nodes to pull images from Docker Hub. There's no zero-cost workaround unless we go to public subnets for nodes (less secure but a course-acceptable shortcut). **Decision below.**

---

## 6. Bootstrap Order (one-time per demo)

```bash
# 1. Provision EKS
cd terraform-eks && terraform init && terraform apply

# 2. Configure kubectl
aws eks update-kubeconfig --region us-west-2 --name skillpulse

# 3. Install ArgoCD (one-time, not via ArgoCD itself — chicken/egg)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace

# 4. Deploy the root ArgoCD Application — it then syncs everything else
kubectl apply -f argocd/root-app.yaml

# 5. Wait for ArgoCD to reconcile
kubectl get applications -n argocd -w

# 6. Port-forward for the demo
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
kubectl port-forward svc/skillpulse-frontend -n skillpulse 8000:80 &
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &
```

Total bootstrap: ~15 min (EKS itself is ~12 min, ArgoCD + sync ~3 min).

**Demo loop:**
1. Open ArgoCD UI → show app tree (skillpulse, observability)
2. Open `http://localhost:8000` → SkillPulse running on EKS
3. Open Grafana → cluster overview, pod CPU/memory, network
4. Edit a frontend file, push to gitops → matrix CI builds new image → ArgoCD detects manifest unchanged but image tag drift (with the right sync policy) → frontend pod rolls. Or simpler: change a manifest (e.g., bump replica count), push, watch ArgoCD self-heal.

---

## 7. ArgoCD App-of-Apps

`argocd/root-app.yaml` is a single Application that points at the `argocd/apps/` directory. ArgoCD reads every YAML there and creates child Applications.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: skillpulse-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/LondheShubham153/SkillPulse.git
    targetRevision: gitops
    path: argocd/apps
    directory: { recurse: true }
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

Then `argocd/apps/skillpulse.yaml` syncs `k8s/`, and `argocd/apps/observability.yaml` is a Helm-flavored Application that installs `kube-prometheus-stack`.

---

## 8. Observability — kube-prometheus-stack

One Helm chart, three tools (all enabled): **Prometheus + Grafana + Alertmanager**. The chart ships with **20+ built-in Grafana dashboards** out of the box — the demo headline is showing them all live, no manual import.

What's included for free (no extra config):

| Category | Dashboards |
|---|---|
| Compute Resources | Cluster, Namespace (Pods), Namespace (Workloads), Node (Pods), Pod, Workload |
| Networking | Cluster, Namespace (Pods), Namespace (Workloads), Pod, Workload |
| Storage | Persistent Volumes |
| Control plane | API Server, Scheduler, Controller Manager, Kubelet, Proxy |
| Nodes | Node Exporter / Nodes, USE Method (Cluster + Node) |
| Stack self-monitoring | Prometheus, Alertmanager |

That's the bulk of the visual demo — open Grafana → sidebar → flip through ~20 polished dashboards showing live metrics from SkillPulse pods, the node, the control plane, and Prometheus itself.

`observability/values.yaml` overrides (kept minimal):
- Tighten Prometheus retention (6h) and scrape interval (30s) — fits comfortably on a t3.large
- Pin Grafana admin password (rather than the chart's random) so the demo doesn't require `kubectl get secret`
- Set Prometheus + Grafana resource requests/limits explicit (predictable scheduling on a single node)

What we deliberately skip:
- Backend `/metrics` instrumentation (would need Gin + Prometheus middleware — out of scope for this demo)
- Custom SkillPulse-specific dashboard JSONs — the default bundle already shows SkillPulse pod CPU/memory/network/storage via the Pod and Workload dashboards filtered by namespace `skillpulse`

If you later want a SkillPulse-branded dashboard, drop a JSON file in `observability/dashboards/` and reference it as a ConfigMap with the `grafana_dashboard: "1"` label — Grafana auto-discovers it. Not needed for the demo.

---

## 9. K8s Manifest Decisions (key ones)

| Decision | Choice | Why |
|---|---|---|
| Namespace | `skillpulse` | isolation, easy `kubectl` filtering |
| Replicas | 1 each (backend, frontend) | single-node cluster anyway |
| Resource requests/limits | tight (e.g., backend: 100m/256Mi req, 500m/512Mi limit) | fit alongside Prometheus on one node |
| MySQL | **Deployment + emptyDir** | ephemeral data, reseeded by init.sql ConfigMap on every pod start; avoids EBS CSI driver / IRSA setup. PVC + StatefulSet is the prod-shaped path. |
| Secrets | k8s `Secret` (base64), checked-in placeholders | course simplicity; flag SealedSecrets/External Secrets as the prod path |
| Images | `:latest` tag | demo-friendly; ArgoCD `imagePullPolicy: Always` to force re-pull on pod restart. Production would pin `:${sha}` and use ArgoCD Image Updater. |
| Service types | ClusterIP only | no LoadBalancer, no Ingress — port-forward for demo |

---

## 10. Cost Estimate (us-west-2, while running)

| Resource | Monthly |
|---|---|
| EKS control plane | ~$73 |
| 1× t3.large node (730 hrs) | ~$60 |
| Single NAT Gateway | ~$32 |
| 5 GiB gp3 PVC (MySQL) | ~$0.40 |
| 20 GiB gp3 EBS root (node) | ~$1.60 |
| Data transfer | ~$1 |
| **Total running 24/7** | **~$168/mo** |
| **Per recording session (apply → record → destroy)** | **~$0.40** |

**NAT Gateway is the biggest non-EKS surprise.** Two options to skip it:
1. **Public subnets for nodes** (saves $32/mo, slightly less secure but fine for a demo cluster with no real data).
2. **VPC Endpoints** for ECR/S3 (cheaper than NAT, but Docker Hub still needs egress).

Recommend option 1 for the demo (locked in §11).

---

## 11. Decisions Locked (proposed defaults — flag any to flip)

| Decision | Choice | Note |
|---|---|---|
| Compute | **EKS** (not k3s) | industry brand wins for a teaching demo |
| Cluster size | **1× t3.large** managed node group | t3.medium was too tight for kube-prometheus-stack + the app on one node |
| Networking | Public subnets for nodes — **no NAT Gateway** | saves ~$32/mo; acceptable for a stateless demo cluster |
| K8s version | 1.32 (verify latest stable at apply time) | EKS supports versions for ~14 months |
| ArgoCD pattern | **App-of-apps** | scales naturally to add more apps later |
| Image tag strategy | `:latest` with `imagePullPolicy: Always` | demo-friendly; flag pinned-`:sha` + ArgoCD Image Updater as the prod path |
| UI access | `kubectl port-forward` | no ALB/Ingress, no DNS/TLS hassle |
| Observability | `kube-prometheus-stack` Helm | one chart = Prometheus + Grafana + node-exporter + kube-state-metrics |
| Custom dashboards | **None — use the 20+ defaults from kube-prometheus-stack** | the default bundle is the demo headline; no manual JSON imports |
| Frontend on k8s | **Yes** (Phase 1 made it image-based) | shows full stack, not just backend |
| Manifest format | Raw YAML in `k8s/` | simpler than Helm/Kustomize for a demo; ArgoCD handles either |
| Secrets handling | k8s `Secret` with checked-in placeholders | flag SealedSecrets / ESO as prod path |

---

## 12. Phase 2 — Produced (status: code in repo, not yet applied)

All scaffolding is on the `gitops` branch. `terraform validate` passes; `terraform plan` shows **47 resources to add, 0 changes, 0 destroys** (VPC + subnets + IGW + route tables + EKS cluster + node group + IAM + access entries + security groups + addons — all module-managed).

```
terraform-eks/                       # Pinned: aws ~> 5.95, eks ~> 20.37, vpc ~> 5.21
  ├── main.tf                        # provider, VPC, EKS modules
  ├── variables.tf                   # region, cluster_name, cluster_version=1.32, node_instance_type=t3.large
  ├── outputs.tf                     # cluster_name, endpoint, region, kubeconfig_command
  ├── terraform.tfvars.example
  └── .gitignore

k8s/                                 # Raw YAML, ArgoCD-friendly, no Helm/Kustomize
  ├── namespace.yaml
  ├── mysql/{deployment,service,configmap-init,secret}.yaml
  ├── backend/{deployment,service,configmap}.yaml
  └── frontend/{deployment,service}.yaml

argocd/                              # App-of-apps — pinned argo-cd Helm chart 9.5.4
  ├── README.md                      # full bootstrap + port-forward + teardown commands
  ├── root-app.yaml
  └── apps/
      ├── skillpulse.yaml            # syncs k8s/ → skillpulse ns
      └── observability.yaml         # multi-source: kube-prometheus-stack 84.2.0 + repo values.yaml

observability/
  └── values.yaml                    # Grafana admin pwd, Prometheus retention 6h, trim resources, drop EKS-unsupported control-plane scrapes
```

### Walkthrough (record this)
1. `cd terraform-eks && terraform apply -auto-approve`   *(~12 min)*
2. `aws eks update-kubeconfig --region us-west-2 --name skillpulse`
3. `helm repo add argo https://argoproj.github.io/argo-helm && helm install argocd argo/argo-cd --version 9.5.4 -n argocd --create-namespace`
4. `kubectl apply -f argocd/root-app.yaml`
5. `kubectl get applications -n argocd -w`   *(skillpulse + observability sync, ~3 min)*
6. Port-forwards (see `argocd/README.md`)
7. Demo: ArgoCD UI tree → SkillPulse on `localhost:8000` → Grafana on `localhost:3000` flipping through 20+ dashboards
8. Edit a manifest, push to `gitops`, watch ArgoCD self-heal
9. `terraform destroy` when done

---

## 13. Open Questions

1. **K8s version pin** — confirm `1.32` is fine, or pick a different supported version.
2. **NAT Gateway shortcut** — public subnets for nodes is locked above; flag if you'd rather pay the $32/mo for the more "production-shaped" private-subnet topology.
3. **Demo flow scripting** — do you want a `make demo` / shell script that runs the bootstrap end-to-end, or step-by-step manual commands during the recording? (Manual is more pedagogical; scripted is faster to redo.)
