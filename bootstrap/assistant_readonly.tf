# Read-only identity for AI assistants (the aws-mcp server) and other tooling
# that should inspect the account but never change it. Enforced by IAM, so it
# holds whichever client or tool uses the credentials.
#
# Used through a CLI profile that assumes this role with your own credentials
# as the source. Deliberately not named "${var.project}-*": the CI deploy role
# may manage roles matching that pattern, including their trust policies.

resource "aws_iam_role" "assistant_readonly" {
  name                 = "assistant-readonly"
  description          = "Read-only access for AI assistants and tooling; cannot change the account."
  assume_role_policy   = data.aws_iam_policy_document.assistant_readonly_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "assistant_readonly" {
  role       = aws_iam_role.assistant_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess includes reading object contents. Terraform state can hold
# secrets, so it is denied explicitly; an explicit Deny overrides any Allow.
data "aws_iam_policy_document" "assistant_readonly_deny" {
  statement {
    sid       = "DenyTerraformState"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }
}

resource "aws_iam_role_policy" "assistant_readonly_deny" {
  name   = "deny-sensitive-reads"
  role   = aws_iam_role.assistant_readonly.id
  policy = data.aws_iam_policy_document.assistant_readonly_deny.json
}

# Who may assume the role.
data "aws_iam_policy_document" "assistant_readonly_trust" {
  # Only the admin IAM user. Naming the user (not the account root) keeps the
  # gate here, so no other identity in the account, including the CI roles,
  # can assume this role even if its own policy allows sts:AssumeRole.
  statement {
    sid     = "AdminUserOnly"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:user/GeoffG"]
    }
  }
}
