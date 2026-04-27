# ArgoCD layout

App-of-apps pattern. ArgoCD itself is bootstrapped via Helm (one-time, outside this directory). After that, everything below is git-managed.

```
argocd/
├── root-app.yaml        # the "app of apps" entry point
└── apps/
    ├── skillpulse.yaml  # syncs k8s/ → skillpulse namespace
    └── observability.yaml  # installs kube-prometheus-stack via Helm → monitoring namespace
```

## Bootstrap (one-time, after `terraform apply` in terraform-eks/)

```bash
# 1. Point kubectl at the new cluster
aws eks update-kubeconfig --region us-west-2 --name skillpulse

# 2. Install ArgoCD via Helm (chicken/egg — can't deploy ArgoCD via ArgoCD)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version 9.5.4 -n argocd --create-namespace

# 3. Wait for ArgoCD pods
kubectl rollout status -n argocd deployment/argocd-server --timeout=5m

# 4. Apply the root Application — ArgoCD picks up everything else
kubectl apply -f argocd/root-app.yaml

# 5. Watch the apps sync
kubectl get applications -n argocd -w
```

## Demo access

```bash
# ArgoCD UI (https://localhost:8080, accept the self-signed cert)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# SkillPulse (http://localhost:8000)
kubectl port-forward svc/frontend -n skillpulse 8000:80 &

# Grafana (http://localhost:3000, login: admin / skillpulse-demo)
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &
```

## Updating

Any commit to the `gitops` branch under `k8s/` or `observability/` is automatically reconciled by ArgoCD within ~3 minutes (or instantly via the UI's "Refresh"). No `kubectl apply` ever again — that's the point.

## Teardown

```bash
# Drop ArgoCD-managed apps first so ArgoCD removes child resources
kubectl delete -f argocd/root-app.yaml

# Then helm uninstall ArgoCD
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# Finally tear down the cluster
cd terraform-eks && terraform destroy -auto-approve
```
