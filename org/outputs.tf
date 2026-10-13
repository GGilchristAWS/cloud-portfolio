output "portfolio_account_id" {
  description = "ID of the portfolio workload account."
  value       = aws_organizations_account.portfolio.id
}

output "workloads_ou_id" {
  description = "ID of the Workloads OU."
  value       = aws_organizations_organizational_unit.workloads.id
}
