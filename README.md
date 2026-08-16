# SkillPulse

Track your skills. Log your learning. Ship via GitHub Actions.

A small full-stack app — **Go + Gin API, MySQL, vanilla-JS frontend behind nginx** —
used as the hands-on project for a TrainWithShubham DevOps course.

The app itself is deliberately simple. **The real subject is what happens around it:**
provisioning infrastructure with Terraform, containerising with Docker Compose, and
shipping every push to production with GitHub Actions. You'll build the whole loop.

---

## What you'll learn

| Topic | Where it lives in this repo |
|---|---|
| Multi-stage Docker builds | `backend/Dockerfile` |
| Multi-container orchestration | `docker-compose.yml` |
| nginx as a static server + reverse proxy | `nginx/nginx.conf` |
| Infrastructure as Code | `terraform/` |
| Cloud-init server bootstrapping | `terraform/user_data.sh.tpl` |
| CI — build and publish an image | `.github/workflows/ci.yml` |
| CD — deploy over SSH | `.github/workflows/cd.yml` |
| Secrets management in CI | GitHub repo secrets |
| **GitOps with Kubernetes** | the [`gitops` branch](#the-gitops-branch) |

---

## Architecture

```
                         ┌──────────────────────────┐
     git push ──────────►│  GitHub Actions          │
                         │  ci.yml  ──►  cd.yml     │
                         └──────┬─────────────┬─────┘
                                │             │
                   image push   │             │  SSH deploy
                                ▼             ▼
                        ┌────────────┐   ┌──────────────────────────────┐
                        │ Docker Hub │──►│  EC2 · Ubuntu 24.04          │
                        └────────────┘   │  ┌───────┐ ┌───────┐ ┌─────┐ │
                                         │  │ nginx │─│backend│─│mysql│ │
                                         │  └───────┘ └───────┘ └─────┘ │
                                         │      docker compose          │
                                         └──────────────┬───────────────┘
                                                        │ :80
                                                        ▼
                                                     You 🎉
```

One EC2 box runs everything — nginx serves the frontend and proxies `/api/` to the Go
backend, which talks to MySQL in a sibling container. No load balancer, no RDS, no
autoscaling. Course-grade simplicity, on purpose.

---

## Run it locally

**Prerequisites:** Docker and Docker Compose.

```bash
git clone https://github.com/LondheShubham153/SkillPulse.git
cd SkillPulse

cp .env.example .env        # then set DOCKERHUB_USERNAME
docker compose up -d

open http://localhost
```

You should see the dashboard with five seeded skills. Check the API directly:

```bash
curl http://localhost/health        # {"status":"healthy"}
curl http://localhost/api/dashboard
```

Tear down with `docker compose down`, or `docker compose down -v` to also wipe the
database volume.

### Working on the backend

`docker-compose.yml` **pulls** the backend image rather than building it, because that's
how the deployed box gets it. To iterate on Go code locally, temporarily point the
`backend` service at your source:

```yaml
  backend:
    # image: ${DOCKERHUB_USERNAME}/skillpulse-backend:latest
    build: ./backend
```

```bash
docker compose up -d --build backend
```

Don't commit that change — production relies on the image path.

You can also run the API straight on your machine. There's no `go.sum` checked in, so
resolve dependencies first:

```bash
cd backend
go mod tidy        # generates go.sum — needed for go build / go vet / your editor too
go run .           # defaults to localhost:3306, so keep the db container up
```

### Working on the frontend

No build step. nginx bind-mounts `./frontend`, so edit HTML/CSS/JS and refresh the page.

---

## API reference

Base path `/api`, served through nginx on port 80.

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/skills` | All skills, each with `total_hours` summed from its logs |
| `POST` | `/api/skills` | Create a skill |
| `GET` | `/api/skills/:id` | One skill plus its learning logs |
| `DELETE` | `/api/skills/:id` | Delete a skill and cascade-delete its logs |
| `POST` | `/api/skills/:id/log` | Log a learning session against a skill |
| `GET` | `/api/dashboard` | Aggregate stats: skill count, total hours, session count, top skill |
| `GET` | `/health` | Liveness — pings the database |

```bash
# Create a skill
curl -X POST http://localhost/api/skills \
  -H 'Content-Type: application/json' \
  -d '{"name":"Kubernetes","category":"DevOps","target_hours":60}'

# Log a session against skill 1
curl -X POST http://localhost/api/skills/1/log \
  -H 'Content-Type: application/json' \
  -d '{"hours":2.5,"notes":"Deployments and services","log_date":"2026-08-16"}'
```

`name` is required on a skill; `hours` and `log_date` are required on a log.

---

## Data model

```
skills                              learning_logs
├── id                              ├── id
├── name          (required)        ├── skill_id  ──► skills.id  (ON DELETE CASCADE)
├── category                        ├── hours     DECIMAL(4,1)
├── target_hours                    ├── notes
└── created_at                      ├── log_date  DATE
                                    └── created_at
```

Schema and seed data live in `mysql/init.sql`. Note that MySQL runs it **only when the
data directory is empty** — on an existing volume, schema edits are ignored until you
`docker compose down -v`.

---

## Deploy to AWS

The full runbook is **[`DEPLOYMENT.md`](DEPLOYMENT.md)** — read it before running
anything that costs money. The short version:

**One-time, from your machine:**

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set repo_url and dockerhub_username
terraform init && terraform apply

terraform output -raw ssh_private_key > skillpulse-key.pem && chmod 600 skillpulse-key.pem
terraform output app_url
```

Then set five GitHub repo secrets — `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `EC2_HOST`,
`EC2_USER`, `EC2_SSH_KEY` (commands in `DEPLOYMENT.md` §7).

**After that, every push to `main` deploys itself:** CI builds and pushes the backend
image, CD SSHes in and runs `git pull` + `docker compose pull` + `docker compose up -d`.

### The one thing that trips everyone up

Changes reach the server by **two different routes**:

| You changed… | It arrives via |
|---|---|
| `backend/` (Go code) | the Docker Hub image, fetched by `docker compose pull` |
| `frontend/`, `nginx/`, `mysql/`, `docker-compose.yml` | `git pull` in the CD workflow |
| `terraform/` | **nothing** — you apply it yourself |

That's why the deploy step runs *both* `git pull` and `docker compose pull`. Drop either
one and half your changes will silently never ship. `DEPLOYMENT.md` §9 explains why.

### Cost

Roughly **$33/month** if you leave it running (t3.medium + 20 GiB gp3), or a few cents
per session if you `terraform destroy` when you're done. **Destroy it when you're done** —
`terraform destroy` is verified to leave nothing behind.

---

## The `gitops` branch

The [`gitops`](../../tree/gitops) branch takes the same application to **Kubernetes**:
EKS provisioned with Terraform, ArgoCD in an app-of-apps layout, and
kube-prometheus-stack for Prometheus + Grafana. Instead of CI pushing to a server,
ArgoCD pulls the desired state from git and reconciles it.

See `GITOPS-DEMO.md` and `argocd/README.md` on that branch. Note it costs considerably
more to run (~$136/month, mostly the EKS control plane), so destroy it promptly.

---

## Project layout

```
backend/        Go API — main.go, handlers/, models/, database/, Dockerfile
frontend/       Static HTML/CSS/JS — no build step
nginx/          nginx server block (static + /api/ reverse proxy)
mysql/          init.sql — schema and seed data
terraform/      EC2, security group, SSH key, cloud-init bootstrap
.github/        ci.yml (build & push) and cd.yml (SSH deploy)
```

---

## A note on scope

This is teaching code. There is no authentication, no HTTPS, no test suite, and the demo
credentials are in the repo on purpose — every one of those is a deliberate simplification
so the pipeline stays readable end to end. `DEPLOYMENT.md` §12 lists every decision and
its rationale. **Don't ship this shape to production**; do understand why each shortcut
was taken, and what the production-grade alternative would be.
