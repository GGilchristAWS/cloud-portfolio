# Human access to the portfolio account goes through IAM Identity Center:
# short-lived credentials from `aws configure sso`, no IAM users in the account.
#
# Prerequisite: permission sets must be enabled on the instance (a one-way
# switch, done once outside Terraform):
#   aws sso-admin update-instance --instance-arn <arn> --permission-sets-enabled

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  # Created by the bootstrap stack in the portfolio account.
  portfolio_tfstate_bucket_arn = "arn:aws:s3:::${var.project}-tfstate-${aws_organizations_account.portfolio.id}"
}

data "aws_identitystore_user" "operator" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.identity_center_user_name
    }
  }
}

# --- Admin: for applying the bootstrap stack --------------------------------

resource "aws_ssoadmin_permission_set" "admin" {
  name             = "PortfolioAdmin"
  description      = "Full access to the portfolio account, for applying its bootstrap stack."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"

  #checkov:skip=CKV_AWS_274:Human break-glass/bootstrap access via short-lived SSO sessions; CI uses scoped roles
}

# --- Read-only: for AI assistants (aws-mcp) and browsing --------------------

resource "aws_ssoadmin_permission_set" "readonly" {
  name             = "PortfolioReadOnly"
  description      = "Read-only access to the portfolio account; cannot read Terraform state."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "readonly" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.readonly.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess includes reading object contents. Terraform state can hold
# secrets, so it is denied explicitly; an explicit Deny overrides any Allow.
data "aws_iam_policy_document" "readonly_deny" {
  statement {
    sid       = "DenyTerraformState"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.portfolio_tfstate_bucket_arn}/*"]
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "readonly" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.readonly.arn
  inline_policy      = data.aws_iam_policy_document.readonly_deny.json
}

# --- Assignments --------------------------------------------------------------

resource "aws_ssoadmin_account_assignment" "operator" {
  for_each = {
    admin    = aws_ssoadmin_permission_set.admin.arn
    readonly = aws_ssoadmin_permission_set.readonly.arn
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = each.value
  principal_type     = "USER"
  principal_id       = data.aws_identitystore_user.operator.user_id
  target_type        = "AWS_ACCOUNT"
  target_id          = aws_organizations_account.portfolio.id
}
