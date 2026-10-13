# cloud-portfolio

A containerized web application on AWS, built to demonstrate cloud operations and architecture practices:

- **Infrastructure as Code**: everything in Terraform, including the GitHub repository and its branch rules
- **Keyless CI/CD**: GitHub Actions authenticates to AWS via OIDC; no access keys exist anywhere
- **Least privilege**: a read-only plan role for pull requests and a scoped deploy role usable only from the protected `production` environment
- **Supply-chain hygiene**: Actions pinned to commit SHAs, immutable image tags, image and IaC scanning on every PR, Dependabot with a 7-day cooldown
- **Cost engineering**: Fargate Spot, no NAT gateway, budgets and anomaly alerts, and an app stack destroyed every night

## Architecture

```
https://portfolio.mirkwood.xyz
   │  Route 53 alias
   ▼
ALB ──:443 TLS 1.3/1.2 (ACM cert, HSTS)──▶ ECS Fargate Spot task :8000
    └─:80 ──301──▶ https                     │  pulls image from ECR
                                             └─ logs to CloudWatch
```

| Path | Lifecycle | Contents |
|---|---|---|
| `bootstrap/` | Long-lived, applied locally by an admin | State bucket, GitHub OIDC provider and CI roles, ECR, alert topic, budgets and anomaly detection, Route 53 zone (CAA, no-mail SPF/DKIM/DMARC/null MX), ACM certificate, read-only assistant role, repository settings and ruleset |
| `infra/` | Ephemeral (~$1/day while up), applied by CI | VPC, ALB (HTTPS + redirect), app DNS alias, ECS cluster/service/task, log group, alarms |
| `app/` | | FastAPI app, Dockerfile, tests |

## Pipeline

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Pull request | Ruff + pytest; image build + Trivy (fails on fixable CRITICAL); `terraform fmt`/`validate`, tflint, Checkov; `terraform plan` of the app stack as the read-only plan role |
| `deploy.yml` | Push to `main` (app/infra changes), or manual | Builds and pushes the image tagged with the commit SHA, applies Terraform as the deploy role, smoke-tests that the ALB serves that commit |
| `teardown.yml` | Nightly 07:00 UTC, or manual | Destroys the app stack |

`main` accepts changes only through pull requests that pass all four CI checks (no bypass, including for admins).

## Running it

- **Bring the app up**: Actions → Deploy → Run workflow. Takes about 5 minutes; the URL is shown on the run.
- **Take it down**: Actions → Teardown → Run workflow, or wait for the nightly run.
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
