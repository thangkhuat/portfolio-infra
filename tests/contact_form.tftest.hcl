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

# Same reason as the three above: aws_lambda_permission.cloudfront_invoke
# pins source_arn to the distribution's ARN, which doesn't exist until
# apply. Without this the source_arn assertion can't be evaluated.
override_resource {
  target          = aws_cloudfront_distribution.portfolio_cdn
  override_during = plan
  values = {
    arn = "arn:aws:cloudfront::000000000000:distribution/E000000000000"
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

# ------------------------------------------------------------
# Routing — CloudFront is the only path to the function
# ------------------------------------------------------------

run "origin_requests_to_the_function_are_signed" {
  command = plan

  assert {
    condition     = aws_cloudfront_origin_access_control.contact_form_oac.origin_access_control_origin_type == "lambda"
    error_message = "The contact form OAC must be of origin type lambda. The S3 OAC cannot be reused, and an origin type mismatch means CloudFront does not sign the requests it sends to the function."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.contact_form_oac.signing_behavior == "always"
    error_message = "Signing behavior must stay 'always'. Set to 'never' this turns OAC off, and CloudFront sends unsigned requests that an AWS_IAM function URL will refuse — or worse, that a NONE function URL would accept from anyone."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.contact_form_oac.signing_protocol == "sigv4"
    error_message = "SigV4 is the only signing protocol Lambda function URLs accept."
  }
}

run "only_this_distribution_may_invoke_the_function" {
  command = plan

  assert {
    condition     = aws_lambda_permission.cloudfront_invoke.source_arn == aws_cloudfront_distribution.portfolio_cdn.arn
    error_message = "The invoke permission must be pinned to this distribution's ARN. Without the source_arn condition the grant lets ANY CloudFront distribution, in any AWS account, invoke the function — which is the whole boundary this feature rests on."
  }

  assert {
    condition     = aws_lambda_permission.cloudfront_invoke.principal == "cloudfront.amazonaws.com"
    error_message = "Only the CloudFront service principal should hold this grant."
  }

  assert {
    condition     = aws_lambda_permission.cloudfront_invoke.action == "lambda:InvokeFunctionUrl"
    error_message = "The grant must be InvokeFunctionUrl, not the broader lambda:InvokeFunction. CloudFront reaches the function through its URL and needs nothing more."
  }

  assert {
    condition     = aws_lambda_permission.cloudfront_invoke.function_url_auth_type == "AWS_IAM"
    error_message = "The permission must be scoped to the AWS_IAM auth type. Scoped to NONE it would grant against an unauthenticated URL, which is the configuration this design exists to avoid."
  }
}

run "form_submissions_are_never_cached_or_sent_in_plaintext" {
  command = plan

  assert {
    condition = one([
      for b in aws_cloudfront_distribution.portfolio_cdn.ordered_cache_behavior :
      b.cache_policy_id if b.path_pattern == "/api/contact"
    ]) == data.aws_cloudfront_cache_policy.caching_disabled.id
    error_message = "/api/contact must use the CachingDisabled policy. Any caching on a form endpoint risks one visitor's submission response being served to another, and makes the request body part of a cache key."
  }

  assert {
    condition = one([
      for b in aws_cloudfront_distribution.portfolio_cdn.ordered_cache_behavior :
      b.viewer_protocol_policy if b.path_pattern == "/api/contact"
    ]) == "https-only"
    error_message = "/api/contact must be https-only, not redirect-to-https. Browsers drop the request body when following a redirect, so a redirected POST silently loses the submission while appearing to succeed."
  }

  assert {
    condition = one([
      for o in aws_cloudfront_distribution.portfolio_cdn.origin :
      one(o.custom_origin_config).origin_protocol_policy
      if o.origin_id == "lambda-contact-form-origin"
    ]) == "https-only"
    error_message = "CloudFront must reach the function over HTTPS only. There is no reason to carry a submitter's name, email and message to AWS in plaintext."
  }
}

# A regression test on a decision made BEFORE this feature. ADR-014
# supersedes ADR-007 for /api/contact only; the default behavior must
# keep forwarding nothing, or the static site quietly loses its cache
# hit rate to a change that was never meant to reach it.
run "adding_the_api_path_did_not_loosen_the_default_behavior" {
  command = plan

  assert {
    condition = alltrue([
      for b in aws_cloudfront_distribution.portfolio_cdn.default_cache_behavior :
      alltrue([for f in b.forwarded_values : f.query_string == false])
    ])
    error_message = "The default behavior must still forward no query string. ADR-007 holds for /*; only /api/contact is the documented exception."
  }

  assert {
    condition = alltrue([
      for b in aws_cloudfront_distribution.portfolio_cdn.default_cache_behavior :
      alltrue([
        for f in b.forwarded_values :
        alltrue([for c in f.cookies : c.forward == "none"])
      ])
    ])
    error_message = "The default behavior must still forward no cookies. ADR-007 holds for /*; only /api/contact is the documented exception."
  }
}