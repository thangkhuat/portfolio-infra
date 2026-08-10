# ============================================================
# Contact form — configuration tests
#
# These assert the security and cost controls that the contact
# form depends on, so that removing one fails loudly instead of
# silently. Run with:
#
#   terraform test
#
# Every provider is mocked, which is the point rather than a
# shortcut. No AWS credentials, no network calls, no resources
# created, nothing billed — so these can run on every commit,
# including from a fork with no access to the account.
#
# The trade-off is explicit: this suite proves what the
# CONFIGURATION says, not what AWS does with it. That is the
# right scope, because none of these controls fail at runtime.
# They fail in a diff — when authorization_type gets set to NONE
# during debugging and never set back.
# ============================================================

# Only the archive provider is mocked, and only so the suite doesn't
# depend on the Lambda source being present or zippable. Nothing asserted
# below concerns the zip.
#
# The aws provider is deliberately NOT mocked. It looked tempting — no
# credentials, no network — but mocking it makes every computed attribute
# unknown, including aws_acm_certificate.domain_validation_options, which
# aws_route53_record.cert_validation does for_each over. for_each must
# know its keys during graph construction, so the plan dies before any
# assertion runs. The real provider computes those keys at plan time,
# which is exactly why the pre-existing ACM chain plans from zero at all.
#
# Consequence: `terraform test` needs AWS credentials. That is consistent
# with this project, where Terraform is only ever run locally by hand.
# No resources are created — every run block below is plan-only.
mock_provider "archive" {}

# ------------------------------------------------------------
# The execution role's policy is built with jsonencode() over ARNs that
# don't exist until apply, so at plan time the whole string is unknown and
# jsondecode() on it can't be evaluated. Pinning those three ARNs makes
# the policy a known value, which is what lets the least-privilege
# assertions below run without creating anything.
#
# The account ID is a placeholder. The real one stays out of this
# repository — it's public — exactly as in docs/bootstrap.md.
# ------------------------------------------------------------

override_resource {
  target          = aws_cloudwatch_log_group.contact_form
  override_during = plan
  values = {
    arn = "arn:aws:logs:ap-southeast-2:000000000000:log-group:/aws/lambda/portfolio-contact-form"
  }
}

override_resource {
  target          = aws_dynamodb_table.contact_submissions
  override_during = plan
  values = {
    arn = "arn:aws:dynamodb:ap-southeast-2:000000000000:table/portfolio-contact-submissions"
  }
}

override_resource {
  target          = aws_ses_domain_identity.portfolio
  override_during = plan
  values = {
    arn = "arn:aws:ses:ap-southeast-2:000000000000:identity/thangkhuat.dev"
  }
}

# ------------------------------------------------------------
# The endpoint is the whole attack surface
# ------------------------------------------------------------

run "function_url_is_not_publicly_invokable" {
  command = plan

  assert {
    condition     = aws_lambda_function_url.contact_form.authorization_type == "AWS_IAM"
    error_message = "Function URL must require SigV4 auth. With authorization_type = NONE anyone on the internet can invoke it directly, and the URL is published in page source the moment the form ships."
  }

  assert {
    condition     = length(aws_lambda_function_url.contact_form.cors) == 0
    error_message = "No CORS block belongs on the function URL. The browser reaches it same-origin via CloudFront at /api/contact; a cors block means it is being exposed cross-origin instead."
  }
}

run "invocation_rate_is_capped" {
  command = plan

  assert {
    condition     = aws_lambda_function.contact_form.reserved_concurrent_executions == 2
    error_message = "The concurrency ceiling is a cost control on a public unauthenticated endpoint: every invocation costs a DynamoDB write and an SES send. Removing it (-1 = unreserved) makes the bill the attack."
  }

  assert {
    condition     = aws_lambda_function.contact_form.timeout <= 30
    error_message = "A long timeout on a public endpoint means a hung or slow-loris request bills for longer. Ten seconds is generous for two AWS API calls."
  }
}

# ------------------------------------------------------------
# Least privilege — the blast radius if the handler is compromised
# ------------------------------------------------------------

run "execution_role_grants_no_wildcards" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.contact_form.policy).Statement :
      s.Resource != "*"
    ])
    error_message = "A statement in the execution role policy grants Resource \"*\". Every statement here is meant to be pinned to one ARN."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.contact_form.policy).Statement :
      s.Effect == "Allow"
    ])
    error_message = "This policy is allow-only by design. A Deny appearing here means the intended scope is being expressed by subtraction, which is harder to reason about."
  }
}

run "handler_can_write_submissions_but_never_read_them" {
  command = plan

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.contact_form.policy).Statement :
      s.Action if s.Sid == "StoreSubmission"
    ]) == "dynamodb:PutItem"
    error_message = "The handler must hold PutItem and nothing else. GetItem/Query/Scan would let a compromised function read back every previous submission; DeleteItem would let it destroy them."
  }
}

run "handler_can_only_send_as_the_noreply_address" {
  command = plan

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.contact_form.policy).Statement :
      try(s.Condition.StringEquals["ses:FromAddress"], null) if s.Sid == "SendNotification"
    ]) == "noreply@thangkhuat.dev"
    error_message = "The ses:FromAddress condition is missing or changed. Verifying the domain authorized EVERY address at thangkhuat.dev, so without this condition a compromised handler could send as a real personal address, DKIM-signed as genuine."
  }
}

run "handler_cannot_create_log_groups" {
  command = plan

  assert {
    condition = !contains(
      one([
        for s in jsondecode(aws_iam_role_policy.contact_form.policy).Statement :
        s.Action if s.Sid == "WriteOwnLogs"
      ]),
      "logs:CreateLogGroup"
    )
    error_message = "CreateLogGroup is not needed: the log group is declared in Terraform with a retention policy. Granting it lets the function create unmanaged groups that never expire."
  }
}

run "only_lambda_can_assume_the_execution_role" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.contact_form.assume_role_policy).Statement :
      s.Principal.Service == "lambda.amazonaws.com"
    ])
    error_message = "The execution role's trust policy must name only the Lambda service. Any other principal is a path to assuming this role from somewhere it was never meant to be used."
  }
}

# ------------------------------------------------------------
# Durability of other people's data
# ------------------------------------------------------------

run "submissions_cannot_be_casually_destroyed" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.contact_submissions.deletion_protection_enabled
    error_message = "Deletion protection must stay on. A submission is a message from someone that no apply can regenerate. Turning this off is a deliberate act, which is exactly why terraform destroy is expected to fail here."
  }

  assert {
    condition     = aws_dynamodb_table.contact_submissions.point_in_time_recovery[0].enabled
    error_message = "Point-in-time recovery must stay on. It is the only guard against a handler bug corrupting records, and it is effectively free at this table size."
  }

  assert {
    condition     = aws_dynamodb_table.contact_submissions.server_side_encryption[0].enabled
    error_message = "The KMS key selection must stay enabled. DynamoDB encrypts regardless, but this is what puts key usage in CloudTrail for a table holding third-party personal data."
  }
}

run "submission_keys_cannot_collide" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.contact_submissions.hash_key == "submission_id"
    error_message = "The partition key must be the server-generated submission_id. PutItem on an existing key REPLACES the item, so keying on anything a submitter controls (their email) lets a second message silently destroy their first."
  }
}

# ------------------------------------------------------------
# Cost — the constraint the whole feature is built around
# ------------------------------------------------------------

run "nothing_bills_while_idle" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.contact_submissions.billing_mode == "PAY_PER_REQUEST"
    error_message = "On-demand billing is why this feature passes the cost test that ADR-009 applied when it destroyed the ALB. Provisioned capacity bills whether or not anyone submits the form."
  }

  assert {
    condition     = aws_cloudwatch_log_group.contact_form.retention_in_days > 0
    error_message = "Log retention must be finite. Zero means never expire, which accrues cost forever and keeps incidental personal data indefinitely."
  }
}

# ------------------------------------------------------------
# Mail identity
# ------------------------------------------------------------

run "mail_is_sent_from_the_site_domain" {
  command = plan

  assert {
    condition     = aws_ses_domain_identity.portfolio.domain == "thangkhuat.dev"
    error_message = "The SES identity must match the site domain, otherwise DKIM signs for a domain the mail does not claim to come from and Gmail treats it as spam."
  }

  assert {
    condition     = length(aws_route53_record.ses_dkim) == 3
    error_message = "SES issues exactly three DKIM tokens and all three CNAMEs must be published. A partial set leaves DKIM unverified, and unsigned mail from a new domain is dropped silently rather than bounced."
  }
}