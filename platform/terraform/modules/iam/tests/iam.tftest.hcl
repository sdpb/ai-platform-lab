# Plan-only tests. The real provider is used (with dummy credentials and no API calls)
# because aws_iam_policy_document is evaluated locally and a mocked one discards its config.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

variables {
  github_org  = "sdpb"
  github_repo = "ai-platform-lab"
  environment = "staging"
}

run "creates_nothing_but_oidc_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.github_actions) == 1
    error_message = "OIDC provider should be created by default."
  }

  assert {
    condition     = length(aws_iam_role.ci_build) == 0 && length(aws_iam_role.cd_deploy) == 0 && length(aws_iam_role.app_runtime) == 0
    error_message = "Roles must be opt-in; none may be created by default."
  }
}

run "deploy_role_is_pinned_to_one_environment" {
  command = plan

  variables {
    create_deploy_role = true
    secret_arns        = ["arn:aws:secretsmanager:us-east-1:111111111111:secret:staging/app-AbCdEf"]
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.cd_deploy_assume_role[0].statement[0].condition : tolist(c.values)
      if c.variable == "token.actions.githubusercontent.com:sub" && c.test == "StringEquals"
    ]) == ["repo:sdpb/ai-platform-lab:environment:staging"]
    error_message = "Deploy role trust must use an exact-match sub claim for the environment (no wildcards)."
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.cd_deploy_assume_role[0].statement[0].condition : tolist(c.values)
      if c.variable == "token.actions.githubusercontent.com:aud"
    ]) == ["sts.amazonaws.com"]
    error_message = "Deploy role trust must require the sts.amazonaws.com audience."
  }

  assert {
    condition     = aws_iam_role.cd_deploy[0].name == "orderlab-cd-deploy-staging-role"
    error_message = "Deploy role name must embed the environment."
  }

  assert {
    condition     = aws_iam_role.cd_deploy[0].max_session_duration == 3600
    error_message = "Deploy sessions must be capped at one hour."
  }
}

run "build_role_is_scoped_to_repo_and_ecr" {
  command = plan

  variables {
    create_build_role  = true
    ecr_repository_arn = "arn:aws:ecr:us-east-1:111111111111:repository/orderlab"
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.ci_build_assume_role[0].statement[0].condition : tolist(c.values)
      if c.variable == "token.actions.githubusercontent.com:sub"
    ]) == ["repo:sdpb/ai-platform-lab:ref:refs/heads/main"]
    error_message = "Build role trust must be limited to the main branch of this repository."
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ci_build_policy[0].statement :
      s.sid == "ECRPush" && contains(s.resources, "arn:aws:ecr:us-east-1:111111111111:repository/orderlab")
    ])
    error_message = "ECR push must be scoped to the given repository ARN."
  }
}

run "runtime_role_has_no_policy_without_secrets" {
  command = plan

  variables {
    create_app_runtime_role = true
  }

  assert {
    condition     = length(aws_iam_role.app_runtime) == 1 && length(aws_iam_role_policy.app_runtime) == 0
    error_message = "Runtime role must not get a policy when no secret ARNs are given."
  }
}

run "reuses_existing_oidc_provider" {
  command = plan

  variables {
    create_oidc_provider       = false
    existing_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
    create_deploy_role         = true
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github_actions) == 0
    error_message = "No new OIDC provider when reusing an existing one."
  }
}

run "supports_immutable_subject_prefix" {
  command = plan

  variables {
    create_deploy_role  = true
    oidc_subject_prefix = "repo:sdpb@53051637/ai-platform-lab@1410420274"
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.cd_deploy_assume_role[0].statement[0].condition : tolist(c.values)
      if c.variable == "token.actions.githubusercontent.com:sub"
    ]) == ["repo:sdpb@53051637/ai-platform-lab@1410420274:environment:staging"]
    error_message = "Deploy role trust must use the immutable subject prefix when given."
  }
}
