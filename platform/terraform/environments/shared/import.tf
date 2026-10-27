# Adopt the GitHub OIDC provider that already exists in this account (made by hand, outside Terraform).
# The module ignores all changes to it and refuses to destroy it. Delete this file for a fresh account.
data "aws_caller_identity" "current" {}

import {
  to = module.iam.aws_iam_openid_connect_provider.github_actions[0]
  id = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}
