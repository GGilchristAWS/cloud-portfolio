# Workload accounts live under their own OU, away from the management account,
# so the organization's SCPs and RCPs apply to them.

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_account" "portfolio" {
  name      = var.project
  email     = var.portfolio_account_email
  parent_id = aws_organizations_organizational_unit.workloads.id
  role_name = "OrganizationAccountAccessRole"

  # Closing an account is slow to undo and the org's SCP denies it anyway;
  # removing this resource only detaches it from Terraform.
  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name] # not returned by the API after creation
  }
}

# --- Region guardrail -------------------------------------------------------
# Created by the console's region-restriction feature; adopted here so changes
# are reviewed. Member accounts may run regional workloads in us-east-2 and
# us-west-2; us-east-1 is limited to global services.

import {
  to = aws_organizations_policy.region_restriction
  id = "p-7tmo2rdn"
}

import {
  to = aws_organizations_policy_attachment.region_restriction_root
  id = "${data.aws_organizations_organization.this.roots[0].id}:p-7tmo2rdn"
}

resource "aws_organizations_policy" "region_restriction" {
  name        = "AdvancedModeRegionRestrictionSecurityControlPolicy"
  description = "AdvancedModeRegionRestrictionSecurityControlPolicy"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/region-restriction.json")
}

resource "aws_organizations_policy_attachment" "region_restriction_root" {
  policy_id = aws_organizations_policy.region_restriction.id
  target_id = data.aws_organizations_organization.this.roots[0].id
}
