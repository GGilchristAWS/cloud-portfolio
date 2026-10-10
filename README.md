# cloud-portfolio

A containerized web application on AWS, built to demonstrate cloud operations and architecture practices:

- **Infrastructure as Code** — everything in Terraform, including the GitHub repository itself
- **Keyless CI/CD** — GitHub Actions authenticates to AWS via OIDC; no stored access keys
- **Least privilege** — separate read-only plan role (pull requests) and deploy role (protected `production` environment)
- **Cost guardrails** — AWS Budgets alerts on gross usage, free-tier-first design, full teardown/rebuild

## Layout

| Path | Purpose |
|---|---|
| `bootstrap/` | One-time foundation, applied locally by an admin: state bucket, GitHub OIDC provider and CI roles, budgets, repository settings |

## Bootstrap

```powershell
cd bootstrap
copy terraform.tfvars.example terraform.tfvars   # set budget_alert_email
$env:GITHUB_TOKEN = gh auth token
terraform init
terraform apply
```
