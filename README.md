# cloud-portfolio

**See it live:** https://portfolio.geoffgilchrist.com is my resume, with a **Launch the demo** button
that brings up everything in this repository on AWS through its real deploy pipeline. The demo
runs at https://demo.portfolio.geoffgilchrist.com, with its live dashboards at
https://grafana.portfolio.geoffgilchrist.com, for two hours per launch.

A containerized web application on AWS, built to demonstrate cloud operations and architecture practices:

- **Infrastructure as Code**: everything in Terraform, including the GitHub repository and its branch rules
- **Keyless CI/CD**: GitHub Actions authenticates to AWS via OIDC; no access keys exist anywhere
- **Least privilege**: a read-only plan role for pull requests and a scoped deploy role usable only from the protected `production` environment
- **Supply-chain hygiene**: Actions pinned to commit SHAs, immutable image tags, image and IaC scanning on every PR, Dependabot with a 7-day cooldown
- **Cost engineering**: Fargate Spot, no NAT gateway, budgets and anomaly alerts, and a demo that runs only on demand: a static resume launches it, and it tears itself down after two hours
- **Observability**: OpenTelemetry traces, metrics and logs in a self-hosted Prometheus, Tempo, Loki and Grafana stack, with dashboards and alert rules as code and the monitoring stack monitoring itself

## Architecture

The resume is always up. Its **Launch the demo** button brings up everything below (about 10
minutes, through the normal Deploy workflow), and the demo tears itself down two hours after
launch. Idle, the whole project costs about $1 a month (the Route 53 zone and its queries); each
two-hour demo session adds about $0.25 (estimated from AWS prices: the ALB, public IPv4 addresses
and Fargate Spot).

```
 https://portfolio.geoffgilchrist.com ─▶ CloudFront ─┬─ /*      ─▶ S3: static resume (rendered from the app's templates)
                                                     └─ /api/*  ─▶ Lambda launcher ─▶ GitHub Actions Deploy (launch)
                                                                    ▲              └─▶ EventBridge Scheduler, +2 h ─▶ Teardown
                                                                    └── capped at 4 launches a day; status, extend (+1 h, once), launch email
```

```
  https://demo.portfolio.geoffgilchrist.com                https://grafana.portfolio.geoffgilchrist.com
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
 Background traffic: k6 in the monitoring task ──▶ ALB ──▶ app, about 3 req/s, so the dashboards are never empty
 Outside the stack: CloudWatch alarms (site down, 5xx, latency, monitoring down) ──▶ SNS ──▶ email
```

### Observability

| Signal | Path | Where to see it |
|---|---|---|
| Traces | app → agent → gateway → **Tempo** (also generates span metrics and the service graph) | Recent traces panel; click an exemplar dot on the latency graph. Trace links open a Trace dashboard rather than Explore, which anonymous viewers can't use |
| Metrics | app and ECS task stats → agent → gateway → **Prometheus** (OTLP receiver); every monitoring component scraped | Golden signals, ECS tasks, monitoring-stack health rows |
| Logs | app logs with trace IDs → agent → gateway → **Loki**; all containers also to CloudWatch Logs | App logs panel; each line links to its trace |
| AWS view | **CloudWatch** data source (ALB, ECS service metrics) | AWS view row |
| Alerts | Prometheus rules for the app, tasks and monitoring stack; CloudWatch alarms outside the stack send email | Active alerts panel; email |
| Background traffic | Every session's monitoring task runs **k6** at about 3 req/s (`obs/config/k6/ambient.js`), labeled `ambient`, so the dashboards are alive from the first minutes | Every graph; "Load-test requests by scenario" |
| Load tests | **k6** scenarios (smoke, ramp, spike, soak, and a ~1 h burn-in running all four) call `/api/simulate`, which answers with a requested latency and error rate; labeled `synthetic`, counted in the SLO | Load testing row; purple markers on every graph |

Telemetry lives as long as the monitoring task (one demo session); CloudWatch Logs keeps the durable copy of logs. Dashboards and rules are reviewed and deployed like code; anonymous visitors get read-only Grafana. Their queries run with the monitoring task's role, which reads CloudWatch metrics only, never logs.

| Path | Lifecycle | Contents |
|---|---|---|
| `bootstrap/` | Long-lived, applied locally by an admin | The foundation: state bucket, GitHub OIDC provider and CI roles, ECR, alert topic, budgets and anomaly detection, repository settings and ruleset. The front door: Route 53 zone (CAA, no-mail records, a 60 s negative TTL so the demo resolves soon after a launch), ACM certificates, the static resume (S3 + CloudFront) and the demo launcher (Lambda, Scheduler role, token parameter, error alarm) |
| `launcher/` | Deployed with `bootstrap/` | The demo launcher's Lambda: status, launch (with a daily cap and an email to the owner), extend, and the teardown timer it sets, cancels and fires |
| `infra/` | On demand, applied by CI | The demo: VPC, ALB (HTTPS + redirect), app and Grafana DNS aliases, ECS cluster with the app and monitoring services (Service Connect, started side by side), the background-traffic container, log groups, alarms |
| `app/` | | FastAPI app, Dockerfile, tests; OpenTelemetry auto-instrumentation |
| `obs/` | Ships with the app stack | Collector, Prometheus, Loki, Tempo and Grafana configs and dashboards (as code), built into a config image; `compose.yaml` runs the same stack locally |
| `loadtest/` | Run on demand | k6 scenarios against the app's token-protected `/api/simulate` endpoint |

The portfolio runs in its own member account of an AWS Organization. The organization itself (OUs, accounts, SCPs, IAM Identity Center permission sets, org-wide budgets) is managed in a separate private landing-zone repository.

## Pipeline

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Pull request | Ruff + pytest; image builds + Trivy (fails on fixable CRITICAL); observability configs checked by each tool's own validator; `terraform fmt`/`validate`, tflint, Checkov; `terraform plan` of the app stack as the read-only plan role |
| `deploy.yml` | Push to `main` (app/infra/obs changes), or manual (the launcher, or Run workflow) | **Images:** tags each with the last commit that changed it (so a dashboard change doesn't redeploy the app, and vice versa) and builds only what's new. **Demo:** a manual run first sets the two-hour teardown timer; Terraform then applies as the deploy role (on a push, only while the demo is up), and the deploy is checked end to end: the ALB serves the new commit, a one-minute k6 smoke run meets its latency and error thresholds, Grafana is healthy, and the background traffic reaches Prometheus. **Resume:** renders and publishes the static page, then loads it in headless Chromium, where its script must get an answer from the launcher |
| `load-test.yml` | Manual | Runs a k6 scenario against production; the job summary links to the dashboard for that time window |
| `teardown.yml` | The launcher, two hours after a launch, or manual | Destroys the app stack |
| `keep-up.yml` | Manual | Cancels the demo's teardown timer, so it stays up until Teardown is run |
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

- **Bring the demo up**: the **Launch the demo** button on the resume, or Actions → Deploy → Run workflow. Takes about 10 minutes. Either way it is torn down two hours later; run Actions → Keep up after a manual Deploy to keep it until you run Teardown. Visitors can extend a session by an hour, once. Both kinds of launch count toward the daily cap of 4, and each launch from the page emails you (browser and referrer).
- **Take it down**: Actions → Teardown → Run workflow, or wait for the scheduled teardown.
- **Launcher token**: a fine-grained GitHub token for this repository only, with Actions read and write, stored in SSM. When it expires (at most a year), the launcher's alarm emails you and the resume shows the launcher as unavailable; create a new one and store it:
  `read -rsp "Token: " t; aws ssm put-parameter --overwrite --type SecureString --name /cloud-portfolio/launcher/github-token --value "$t"; unset t`
- **Dashboards**: https://grafana.portfolio.geoffgilchrist.com (public, read-only). Admin password: `aws ssm get-parameter --with-decryption --name /cloud-portfolio/grafana/admin-password`.
- **Walkthrough and screenshots**: set `walkthrough_url` and add screenshots in `app/site/media.toml`; the resume's "How the demo works" section shows them for visitors who won't wait.
- **Load test**: Actions → Load test → Run workflow, then pick a scenario. `spike` fires the error-rate and SLO burn-rate alerts on purpose; `burnin` runs every stage in about an hour; `art` paints a pixel-art Starry Night (or any short text) on the latency heatmap.
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

Checkov findings that are deliberate for a low-cost demo are skipped inline on each resource with the reason. In summary: no WAF, no DNSSEC, no KMS customer-managed keys, no ALB or CloudFront access logs or VPC flow logs, short log retention, and tasks with public IPs instead of a NAT gateway (inbound restricted to the ALB security group). The launch button is public on purpose; what it can cost is bounded by the daily cap of 4 launches, the one-hour limit on extensions, and the budget alerts.

## License

The code is [MIT](LICENSE) licensed. The résumé content in `app/src/portfolio/resume.toml` is personal and not covered by it. The tools the stack runs (Grafana, Loki, Tempo, k6, Prometheus, the OpenTelemetry Collector and others) are used unmodified under their own licenses.
