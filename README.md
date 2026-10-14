# cloud-portfolio

A containerized web application on AWS, built to demonstrate cloud operations and architecture practices:

- **Infrastructure as Code**: everything in Terraform, including the GitHub repository and its branch rules
- **Keyless CI/CD**: GitHub Actions authenticates to AWS via OIDC; no access keys exist anywhere
- **Least privilege**: a read-only plan role for pull requests and a scoped deploy role usable only from the protected `production` environment
- **Supply-chain hygiene**: Actions pinned to commit SHAs, immutable image tags, image and IaC scanning on every PR, Dependabot with a 7-day cooldown
- **Cost engineering**: Fargate Spot, no NAT gateway, budgets and anomaly alerts, and an app stack destroyed every night
- **Observability**: OpenTelemetry traces, metrics and logs in a self-hosted Prometheus, Tempo, Loki and Grafana stack, with dashboards and alert rules as code and the monitoring stack monitoring itself

## Architecture

```
  https://portfolio.geoffgilchrist.com                     https://grafana.portfolio.geoffgilchrist.com
                    │                                                            │
                    │   Route 53 aliases (portfolio.geoffgilchrist.com zone)     │
                    ▼                                                            ▼
   ALB  :443 TLS 1.3/1.2 · ACM wildcard cert · HSTS · :80 → 301 https · routes by host name
                    │                                                            │
 ┌──────────────────▼─────────────────────────────────┐            ┌─────────────▼──────────────────────────────────────┐
 │ APP SERVICE · 2 tasks across 2 AZs                 │            │ MONITORING SERVICE · 1 task                        │
 │                                                    │            │                                                    │
 │ app :8000   FastAPI + OpenTelemetry                │            │ Grafana :3000  dashboards, alerts (as code)        │
 │    │ OTLP over localhost                           │            │    ▲ PromQL / TraceQL / LogQL                      │
 │ otel-agent  sidecar Collector                      ├────────────▶ otel-collector ─┬─▶ Prometheus  metrics, rules     │
 │    + this task's CPU/memory/network                │  OTLP via  │   (gateway)     ├─▶ Tempo  traces, service graph   │
 │      from the ECS metadata endpoint                │  Service   │                 └─▶ Loki   logs (with trace IDs)   │
 │                                                    │  Connect   │ Prometheus scrapes every component, itself too     │
 └────────────────────────────────────────────────────┘            └────────────────────────────────────────────────────┘

 ECR: app + obs-config images (per component) · CloudWatch Logs: every container · Grafana reads CloudWatch (ALB, ECS)
 Outside the stack: CloudWatch alarms (site down, 5xx, latency, monitoring down) ──▶ SNS ──▶ email
```

### Observability

| Signal | Path | Where to see it |
|---|---|---|
| Traces | app → agent → gateway → **Tempo** (also generates span metrics and the service graph) | Recent traces panel; click an exemplar dot on the latency graph |
| Metrics | app and ECS task stats → agent → gateway → **Prometheus** (OTLP receiver); every monitoring component scraped | Golden signals, ECS tasks, monitoring-stack health rows |
| Logs | app logs with trace IDs → agent → gateway → **Loki**; all containers also to CloudWatch Logs | App logs panel; each line links to its trace |
| AWS view | **CloudWatch** data source (ALB, ECS service metrics) | AWS view row |
| Alerts | Prometheus rules for the app, tasks and monitoring stack; CloudWatch alarms outside the stack send email | Active alerts panel; email |
| Load tests | **k6** scenarios (smoke, ramp, spike, soak, and a ~1 h burn-in running all four) call `/api/simulate`, which answers with a requested latency and error rate; labeled `synthetic`, counted in the SLO | Load testing row; purple markers on every graph |

Telemetry lives as long as the monitoring task (the stack is torn down nightly); CloudWatch Logs keeps the durable copy of logs. Dashboards and rules are reviewed and deployed like code; anonymous visitors get read-only Grafana.

| Path | Lifecycle | Contents |
|---|---|---|
| `bootstrap/` | Long-lived, applied locally by an admin | State bucket, GitHub OIDC provider and CI roles, ECR, alert topic, budgets and anomaly detection, Route 53 zone (CAA, no-mail SPF/DKIM/DMARC/null MX), ACM certificate, repository settings and ruleset |
| `infra/` | Ephemeral (~$1/day while up), applied by CI | VPC, ALB (HTTPS + redirect), app and Grafana DNS aliases, ECS cluster with the app and monitoring services (Service Connect), log groups, alarms |
| `app/` | | FastAPI app, Dockerfile, tests; OpenTelemetry auto-instrumentation |
| `obs/` | Ships with the app stack | Collector, Prometheus, Loki, Tempo and Grafana configs and dashboards (as code), built into a config image; `compose.yaml` runs the same stack locally |
| `loadtest/` | Run on demand | k6 scenarios against the app's token-protected `/api/simulate` endpoint |

The portfolio runs in its own member account of an AWS Organization. The organization itself (OUs, accounts, SCPs, IAM Identity Center permission sets, org-wide budgets) is managed in a separate private landing-zone repository.

## Pipeline

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Pull request | Ruff + pytest; image builds + Trivy (fails on fixable CRITICAL); observability configs checked by each tool's own validator; `terraform fmt`/`validate`, tflint, Checkov; `terraform plan` of the app stack as the read-only plan role |
| `deploy.yml` | Push to `main` (app/infra/obs changes), or manual | Tags each image with the last commit that changed it (so a dashboard change doesn't redeploy the app, and vice versa), builds only what's new, applies Terraform as the deploy role, smoke-tests that the ALB serves the app's commit and that Grafana is healthy |
| `load-test.yml` | Manual | Runs a k6 scenario against production; the job summary links to the dashboard for that time window |
| `teardown.yml` | Nightly 07:00 UTC, or manual | Destroys the app stack |
| `tool-drift.yml` | Monthly, or manual | Reports CI tool versions Dependabot can't update and keeps one issue open while any are behind |

`main` accepts changes only through pull requests that pass all four CI checks (no bypass, including for admins).

### Dependency updates

| Step | How |
|---|---|
| Propose | Dependabot, weekly (Monday 08:00 Pacific), for Actions, Python, base images, Terraform providers and the observability images. Releases younger than 14 days (30 for a major) are skipped; security fixes aren't. Minor and patch updates are grouped; each major gets its own PR. |
| One pin per version | Observability and k6 images are pinned only in `obs/compose.yaml`; Terraform (`yamldecode`) and CI read them from there, so a bump changes one line and CI tests exactly what deploys. |
| Verify | The normal CI checks, plus starting the whole observability stack and requiring every component healthy and the app's telemetry to arrive. |
| Roll out | The normal deploy. Per-component image tags mean an observability bump replaces only the monitoring task. A one-minute k6 smoke run with latency and error thresholds fails the deploy if the upgrade made the app worse. |
| Undo | Revert the bump PR; the deploy restores the previous version. |
| Catch the rest | `tool-drift.yml` reports pins inside workflow steps (Terraform, tflint, Trivy, checkov, uv) that are behind or disagree with each other. |

## Running it

- **Bring the app up**: Actions → Deploy → Run workflow. Takes about 5 minutes; the URL is shown on the run.
- **Take it down**: Actions → Teardown → Run workflow, or wait for the nightly run.
- **Dashboards**: https://grafana.portfolio.geoffgilchrist.com (public, read-only). Admin password: `aws ssm get-parameter --with-decryption --name /cloud-portfolio/grafana/admin-password`.
- **Load test**: Actions → Load test → Run workflow, then pick a scenario. `spike` fires the error-rate and SLO burn-rate alerts on purpose; `burnin` runs every stage in about an hour.
- **Run the observability stack locally**: `docker compose -f obs/compose.yaml up --build`, then http://localhost:3000.
- **Change the foundation** (`bootstrap/`): apply locally with admin credentials. CI cannot modify it.

```powershell
cd bootstrap
copy terraform.tfvars.example terraform.tfvars   # set budget_alert_email
$env:GITHUB_TOKEN = gh auth token
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Accepted risks

Checkov findings that are deliberate for a low-cost demo are skipped inline on each resource with the reason. In summary: no WAF, no DNSSEC, no KMS customer-managed keys, no ALB access logs or VPC flow logs, short log retention, and tasks with public IPs instead of a NAT gateway (inbound restricted to the ALB security group).
