# ============================================================
# Portfolio Site Infrastructure — thangkhuat.dev
# See docs/decision-log.md for the reasoning behind choices
# marked with an ADR reference below.
# ============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # pinned major version — avoid an unreviewed breaking change
    }

    # Zips the Lambda source at plan time. Keeps the repo free of a build
    # step: the deployment package is one dependency-free .py file, so
    # there is nothing to install or bundle first.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# Primary provider — everything defaults here unless explicitly
# routed through the us_east_1 alias defined further down.
provider "aws" {
  region = "ap-southeast-2"
}

# ------------------------------------------------------------
# DNS — Route 53 hosted zone
# ------------------------------------------------------------

resource "aws_route53_zone" "portfolio" {
  name = "thangkhuat.dev"
}

# Nameservers to hand to the registrar (Porkbun) to delegate
# DNS control to AWS.
output "name_servers" {
  value = aws_route53_zone.portfolio.name_servers
}

# ------------------------------------------------------------
# Storage — private S3 bucket for the static site files
# ADR-006: kept fully private, served only through CloudFront.
# S3's built-in static website hosting was rejected — it requires
# a public bucket and doesn't support HTTPS on a custom domain.
# ------------------------------------------------------------

resource "aws_s3_bucket" "portfolio_site" {
  bucket = "thangkhuat-dev-portfolio" # must be globally unique across all AWS accounts
}

# Belt-and-braces: blocks public access even if a policy or ACL
# is ever misconfigured later.
resource "aws_s3_bucket_public_access_block" "portfolio_site" {
  bucket = aws_s3_bucket.portfolio_site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront's ACM certificate lookup only checks the us-east-1
# API, regardless of where CloudFront itself serves traffic from.
# This is a platform constraint, not a design choice.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ------------------------------------------------------------
# TLS certificate — ACM, DNS-validated
# Requested in us-east-1 via the provider alias above.
# ------------------------------------------------------------

resource "aws_acm_certificate" "portfolio_cert" {
  provider          = aws.us_east_1
  domain_name       = "thangkhuat.dev"
  validation_method = "DNS" # enables full automation — no manual email click required

  lifecycle {
    # Build the replacement cert before destroying the old one,
    # so there's never a window with no valid certificate at all.
    create_before_destroy = true
  }
}

# Auto-creates the random CNAME record ACM needs to see before
# it will issue the certificate — no manual copy-paste required.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.portfolio_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60 # short — this record only ever needs to be read once by ACM
  type            = each.value.type
  zone_id         = aws_route53_zone.portfolio.zone_id
}

# Creates nothing itself — polls until ACM confirms it has seen
# the validation record and issued the certificate. Everything
# downstream references THIS resource (not the raw cert above),
# which is what makes Terraform wait for validation automatically.
resource "aws_acm_certificate_validation" "portfolio_cert" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.portfolio_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ------------------------------------------------------------
# CDN — CloudFront distribution + Origin Access Control
# ADR-006: OAC is the only thing ever allowed to read the bucket.
# ------------------------------------------------------------

# Represents this specific CloudFront distribution's identity.
# Every request it makes to S3 is signed (SigV4) to prove it's
# genuinely this distribution — not just any request claiming to be.
resource "aws_cloudfront_origin_access_control" "portfolio_oac" {
  name                              = "portfolio-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "portfolio_cdn" {
  enabled             = true
  default_root_object = "index.html" # served when visiting the bare domain with no path
  aliases             = ["thangkhuat.dev"] # accept requests for the real domain, not just *.cloudfront.net

  origin {
    domain_name              = aws_s3_bucket.portfolio_site.bucket_regional_domain_name
    origin_id                = "s3-portfolio-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.portfolio_oac.id
  }

  # ADR-012: the contact form's Lambda, reached at /api/contact below.
  origin {
    # function_url is a full URL (https://<id>.lambda-url...on.aws/);
    # CloudFront wants a bare hostname.
    domain_name              = trimsuffix(trimprefix(aws_lambda_function_url.contact_form.function_url, "https://"), "/")
    origin_id                = "lambda-contact-form-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.contact_form_oac.id

    # A function URL is a custom origin, not an S3 one, so unlike the
    # block above it needs its protocol spelled out. https-only rather
    # than match-viewer: there is no reason to ever reach AWS in plaintext.
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"] # a static site is only ever read, never written to
    cached_methods          = ["GET", "HEAD"]
    target_origin_id        = "s3-portfolio-origin"
    viewer_protocol_policy  = "redirect-to-https" # plain HTTP requests get bounced to HTTPS

    # ADR-007: nothing on this static site varies by query string
    # or cookie, so don't forward either — maximizes cache hit rate.
    # Revisit once Phase 2 adds a dynamic backend that needs them.
    #
    # No Cache-Control header is set on the S3 origin, so CloudFront
    # falls back to its default_ttl of 86400s (24h) — a cached copy
    # can be served for up to 24h before an edge re-checks with S3.
    # `aws cloudfront create-invalidation` forces an immediate expiry
    # instead of waiting out that clock.
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # ADR-014: supersedes ADR-007, but narrowly. The default behavior above
  # keeps forwarding nothing and keeps its cache hit rate; this one path
  # forwards everything and caches nothing. Only the exception moved.
  ordered_cache_behavior {
    # The exact path, not /api/* — nothing broader needs routing, and a
    # wildcard would send unrelated future paths at this function.
    path_pattern     = "/api/contact"
    target_origin_id = "lambda-contact-form-origin"

    # CloudFront accepts only GET/HEAD, those plus OPTIONS, or all seven.
    # A form POST needs the full set; the handler itself 405s anything
    # that isn't POST, so the narrowing happens there instead.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # https-only, NOT redirect-to-https like the default behavior.
    # Browsers drop the request body when following a redirect, so
    # bouncing a POST would silently discard the submission and return a
    # confusing success. Refusing plain HTTP outright is the honest failure.
    viewer_protocol_policy = "https-only"

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  # ADR-008: no restriction — audience is recruiters globally
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # References the VALIDATED cert resource, not the raw request —
    # this is what makes Terraform wait for validation to finish
    # before CloudFront can be created.
    acm_certificate_arn      = aws_acm_certificate_validation.portfolio_cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021" # explicit floor — refuses older, insecure TLS versions
  }
}

# ------------------------------------------------------------
# Bucket policy — grants read access to CloudFront's OAC only
# ------------------------------------------------------------

resource "aws_s3_bucket_policy" "portfolio_site" {
  bucket = aws_s3_bucket.portfolio_site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontOAC"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject" # read individual files only — no list, write, or delete
        Resource  = "${aws_s3_bucket.portfolio_site.arn}/*"
        Condition = {
          # Narrows this to THIS specific distribution's ARN —
          # not just any CloudFront distribution, anywhere.
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.portfolio_cdn.arn
          }
        }
      }
    ]
  })
}

# ------------------------------------------------------------
# DNS — alias record mapping the domain to CloudFront
# This is the record that actually makes thangkhuat.dev resolve
# to anything. Without it, everything above still works — it's
# just only reachable via CloudFront's own ugly *.cloudfront.net domain.
# ------------------------------------------------------------

resource "aws_route53_record" "portfolio_alias" {
  zone_id = aws_route53_zone.portfolio.zone_id
  name    = "thangkhuat.dev"
  type    = "A"

  alias {
    # Points at CloudFront's own domain name rather than a fixed
    # IP — CloudFront has no single fixed IP, it's spread across
    # edge locations worldwide, so this has to resolve dynamically.
    name                   = aws_cloudfront_distribution.portfolio_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.portfolio_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

# Needed after every deploy to run `aws cloudfront create-invalidation`.
# Pull it live with `terraform output cloudfront_distribution_id` rather
# than hardcoding it anywhere — if this distribution is ever destroyed
# and recreated, AWS assigns a new ID and a hardcoded copy would go stale.
output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.portfolio_cdn.id
}

# ------------------------------------------------------------
# CI/CD identity — GitHub Actions via OIDC
# ADR-010: the deploy workflow exchanges a short-lived, GitHub-signed
# OIDC token for temporary AWS credentials. No long-lived IAM user
# access keys are stored in GitHub at all.
# ------------------------------------------------------------

# One-time registration telling this AWS account that tokens signed by
# GitHub's issuer are worth validating. Without it, STS has no reason
# to believe a GitHub-issued token at all.
#
# No thumbprint_list on purpose: since mid-2023 AWS validates this
# endpoint against its own trusted CA store. Pinning a leaf certificate
# fingerprint here — as older guides do — would only plant a hardcoded
# value that breaks silently the next time GitHub rotates certs.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience the workflow asks for. configure-aws-credentials sets
  # this to sts.amazonaws.com; a token minted for anything else is
  # rejected before the sub condition below is even considered.
  client_id_list = ["sts.amazonaws.com"]
}

# The role the deploy workflow assumes. Its trust policy is the real
# security boundary — every Actions run on GitHub can obtain a valid
# OIDC token, so the provider alone proves only "some GitHub workflow",
# not which one. The sub condition is what makes it *this* one.
resource "aws_iam_role" "github_actions_deploy" {
  name = "github-actions-portfolio-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"

            # Repo AND branch. Dropping this line — or loosening it to a
            # wildcard — is the classic OIDC misconfiguration: it leaves
            # the role assumable from any repository on GitHub. A fork or
            # a PR branch produces a different sub and is denied.
            #
            # The @<number> suffixes are GitHub's immutable identifiers:
            # 177017208 is the owner ID, 1322692264 the repo ID. GitHub now
            # issues the sub claim in this form rather than the older
            # name-only "repo:owner/name:ref:...". Matching the numeric
            # form is strictly stronger — names can be renamed or, after a
            # delete, re-registered by someone else; these IDs cannot.
            #
            # Verified against the real claim in CloudTrail, not assumed.
            # If a deploy ever fails with "Not authorized to perform
            # sts:AssumeRoleWithWebIdentity", check this claim first:
            #   aws cloudtrail lookup-events --lookup-attributes \
            #     AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity
            "token.actions.githubusercontent.com:sub" = "repo:thangkhuat@177017208/portfolio-infra@1322692264:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

# Scoped to exactly the two API calls the deploy workflow makes. Worst
# case if the workflow is ever compromised: the site gets defaced. The
# role can't read the bucket, delete from it, or reach anything else.
resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "portfolio-deploy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteSiteFiles"
        Effect = "Allow"
        # Upload only — no GetObject, no DeleteObject, no ListBucket.
        # Switching the workflow to `aws s3 sync --delete` would need
        # both s3:DeleteObject and s3:ListBucket added here.
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.portfolio_site.arn}/*"
      },
      {
        Sid      = "InvalidateCdnCache"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = aws_cloudfront_distribution.portfolio_cdn.arn # this distribution only
      }
    ]
  })
}

# Goes into the repo's GitHub Actions *variable* AWS_ROLE_ARN — a
# variable, not a secret. An ARN is an identifier, not a credential:
# holding it grants nothing, because the trust policy above is what
# actually gates access. Keeping it out of the committed workflow only
# avoids publishing the account ID in a public repo's git history.
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions_deploy.arn
}

# ------------------------------------------------------------
# Contact form — submission store (DynamoDB)
# ADR-011: on-demand billing means an idle table costs nothing,
# which is the same cost test that ruled out the ALB in ADR-009.
# ------------------------------------------------------------

resource "aws_dynamodb_table" "contact_submissions" {
  name = "portfolio-contact-submissions"

  # No provisioned capacity to size or pay for while idle. At this
  # volume the table sits inside the always-free tier entirely.
  billing_mode = "PAY_PER_REQUEST"

  # A server-generated UUID. Keying on something meaningful — the
  # submitter's email, say — would let a second message from the same
  # person silently overwrite the first, since PutItem on an existing
  # key replaces the item rather than failing.
  hash_key = "submission_id"

  # Only key attributes are declared. Everything else the handler writes
  # (name, email, message, submitted_at) needs no declaration — DynamoDB
  # is schemaless apart from its keys.
  attribute {
    name = "submission_id"
    type = "S"
  }

  # DynamoDB always encrypts at rest; this switches the default AWS-owned
  # key for an AWS-managed KMS key, so key usage shows up in CloudTrail.
  # Costs ~$0.03/10k requests — worth it for a table holding other
  # people's names, emails, and messages.
  server_side_encryption {
    enabled = true
  }

  # Continuous backups, restorable to any second in the last 35 days.
  # Priced on stored bytes, so effectively free at this size. Guards
  # against a handler bug corrupting records — not against the table
  # itself being dropped, which is what the next setting is for.
  point_in_time_recovery {
    enabled = true
  }

  # A submission is a message from someone that cannot be regenerated:
  # no `terraform apply` brings it back.
  #
  # NOTE: this makes `terraform destroy` fail on this table until the
  # flag is set to false and applied first. That's the intended friction
  # — see docs/bootstrap.md.
  deletion_protection_enabled = true
}

# ------------------------------------------------------------
# Contact form — email delivery (SES)
# ADR-013: the account stays in the SES sandbox deliberately. Sending
# only ever goes to one pre-verified address, so the sandbox's
# verified-recipients-only rule costs nothing and acts as a hard
# containment control enforced outside this account's own code.
# ------------------------------------------------------------

# Verifying the DOMAIN authorizes every address at thangkhuat.dev —
# including the noreply@ sender — without verifying each one. It's also
# the only form of verification Terraform can complete unaided: the proof
# is a DNS record, and the hosted zone is already managed above. Verifying
# a single address instead would mean clicking a link mid-build, for
# something Terraform can do by itself.
#
# The older aws_ses_* resources are used rather than aws_sesv2_*: v2 has
# no equivalent of the verification waiter below, and losing it would put
# a race on the first apply.
resource "aws_ses_domain_identity" "portfolio" {
  domain = "thangkhuat.dev"
}

resource "aws_route53_record" "ses_verification" {
  zone_id = aws_route53_zone.portfolio.zone_id
  name    = "_amazonses.thangkhuat.dev"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.portfolio.verification_token]
}

# DKIM signs outgoing mail so a receiver can prove it genuinely came from
# this domain. Not cosmetic: unsigned machine-sent mail from a new domain
# with a noreply@ sender, carrying a stranger's name and message, is
# indistinguishable from spam. Gmail drops it silently — the form would
# appear to work, with a 200 and a stored row, while no email ever arrived.
resource "aws_ses_domain_dkim" "portfolio" {
  domain = aws_ses_domain_identity.portfolio.domain
}

# count, not for_each — and deliberately, despite for_each being the better
# default. for_each has to know its keys at PLAN time in order to name the
# instances, and the DKIM tokens don't exist until SES has been created:
#
#   Error: Invalid for_each argument
#   aws_ses_domain_dkim.portfolio.dkim_tokens is a list of string,
#   known only after apply
#
# That error blocks planning the entire configuration, not just this
# resource. count only needs the length, which is the literal below — SES
# always issues exactly three tokens — so the values can stay unknown
# until apply.
#
# The cost is real: count keys by list position, so if SES ever reordered
# the tokens Terraform would destroy and recreate records that hadn't
# actually changed. Accepted, because the alternative doesn't plan at all.
resource "aws_route53_record" "ses_dkim" {
  count = 3

  zone_id = aws_route53_zone.portfolio.zone_id
  name    = "${aws_ses_domain_dkim.portfolio.dkim_tokens[count.index]}._domainkey.thangkhuat.dev"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.portfolio.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# Creates nothing — polls until SES confirms it has seen the TXT record
# above. This is the same indirection as aws_acm_certificate_validation
# further up the file: the Lambda's IAM policy references THIS resource
# rather than the identity, which is what makes Terraform wait for
# verification instead of building a function whose first send would fail.
resource "aws_ses_domain_identity_verification" "portfolio" {
  domain     = aws_ses_domain_identity.portfolio.id
  depends_on = [aws_route53_record.ses_verification]
}

# The sandbox only delivers to verified recipients, so the destination
# needs an identity of its own. Terraform creates it and SES sends the
# confirmation mail, but the link has to be clicked by hand — Terraform
# can't read an inbox. Until that happens the identity sits Pending and
# every send fails. Recorded in docs/bootstrap.md alongside the other
# steps Terraform deliberately doesn't own.
#
# Same address as the mailto: link in index.html. Splitting the two — a
# public one for the link, a private one for submissions — is a
# reasonable later change, and this is the only line it would need.
resource "aws_ses_email_identity" "notification_recipient" {
  email = "huuthang.khuat21@gmail.com"
}

# ------------------------------------------------------------
# Contact form — compute (Lambda + function URL)
# ADR-011: serverless, because an idle function costs nothing. The
# same cost test that destroyed the always-on ALB in ADR-009.
# ------------------------------------------------------------

# Zipped at plan time from a single dependency-free source file. boto3
# ships in the Python runtime, so there is nothing to pip install and the
# repo keeps its "no build step" property.
data "archive_file" "contact_form" {
  type        = "zip"
  source_file = "${path.module}/lambda/contact_form/handler.py"
  output_path = "${path.module}/build/contact_form.zip"
}

# Declared rather than left to Lambda, which auto-creates its log group on
# first invocation with retention set to Never Expire — an unbounded bill
# and unbounded retention of incidental personal data. Terraform also then
# owns it, so `destroy` cleans it up, and the role below can be scoped to
# this exact ARN.
resource "aws_cloudwatch_log_group" "contact_form" {
  name              = "/aws/lambda/portfolio-contact-form"
  retention_in_days = 14
}

resource "aws_iam_role" "contact_form" {
  name = "portfolio-contact-form"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# Hand-scoped rather than attaching the managed AWSLambdaBasicExecutionRole,
# which grants log writes against arn:aws:logs:*:*:* — every log group in
# the account. The rest of this file pins IAM to exact ARNs, and the
# function holding other people's personal details is not the place to
# stop doing that.
resource "aws_iam_role_policy" "contact_form" {
  name = "portfolio-contact-form"
  role = aws_iam_role.contact_form.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteOwnLogs"
        Effect = "Allow"
        # No CreateLogGroup: the group is declared above, and the function
        # has no reason to be able to create others.
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.contact_form.arn}:*"
      },
      {
        Sid    = "StoreSubmission"
        Effect = "Allow"
        # Write only. No GetItem, Query, or Scan — the handler never reads,
        # so a compromised function cannot pull back earlier submissions.
        # No DeleteItem either, so it cannot destroy them.
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.contact_submissions.arn
      },
      {
        Sid      = "SendNotification"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = aws_ses_domain_identity.portfolio.arn
        Condition = {
          # Verifying the domain authorized every address at
          # thangkhuat.dev. This narrows the function to exactly one
          # sender, so a compromised handler cannot send as a real
          # personal address from a domain that would DKIM-sign it as
          # genuine. Together with the SES sandbox (ADR-013), the worst
          # case is mail from noreply@ to one pre-verified recipient.
          StringEquals = {
            "ses:FromAddress" = "noreply@thangkhuat.dev"
          }
        }
      }
    ]
  })
}

resource "aws_lambda_function" "contact_form" {
  function_name = "portfolio-contact-form"
  role          = aws_iam_role.contact_form.arn
  runtime       = "python3.12"

  # <file>.<function> — handler.py, and the function named handler in it.
  handler = "handler.handler"

  filename = data.archive_file.contact_form.output_path
  # Without this Terraform cannot tell that handler.py changed: the
  # filename never moves, so an edit would silently never deploy.
  source_code_hash = data.archive_file.contact_form.output_base64sha256

  # Lambda sells CPU in proportion to memory, so 128MB would mostly buy a
  # slower cold start while Python imports boto3. Twice the price per ms
  # over meaningfully fewer ms is close to a wash on the bill.
  memory_size = 256
  timeout     = 10

  # A hard ceiling on concurrent copies, and the reason a flood of
  # requests cannot turn into a bill: every invocation costs a DynamoDB
  # write and an SES send. No legitimate use of a personal contact form
  # needs a third simultaneous slot.
  #
  # This caps the rate, not the total — a patient attacker still gets two
  # at a time indefinitely. Per-IP rate limiting was considered and
  # deferred; see ADR-015.
  reserved_concurrent_executions = 2

  # Keeps AWS account facts out of the Python, so the handler stays
  # portable and renaming the table doesn't mean editing code.
  environment {
    variables = {
      SUBMISSIONS_TABLE = aws_dynamodb_table.contact_submissions.name
      SES_FROM_ADDRESS  = "noreply@thangkhuat.dev"
      SES_TO_ADDRESS    = aws_ses_email_identity.notification_recipient.email
    }
  }

  depends_on = [
    # Without this the function could log before its group exists, and
    # Lambda would create an unmanaged one with no retention.
    aws_cloudwatch_log_group.contact_form,

    # References the VALIDATION resource, not the identity — the same
    # indirection as ACM. It is what stops Terraform building a function
    # whose first send would fail because SES hasn't confirmed the domain.
    aws_ses_domain_identity_verification.portfolio,
  ]
}

# AWS_IAM, not NONE, and this is the security boundary for the whole
# feature. With NONE the URL is invokable by anyone on the internet who
# learns it — and it would appear in page source the moment the form
# shipped. With AWS_IAM every request must carry a valid SigV4 signature,
# and the resource policy in the next section names exactly one caller:
# this CloudFront distribution.
#
# No cors block, deliberately. The browser reaches this through CloudFront
# at /api/contact — same origin as the page — so CORS never enters into it.
resource "aws_lambda_function_url" "contact_form" {
  function_name      = aws_lambda_function.contact_form.function_name
  authorization_type = "AWS_IAM"
}

# Curling this directly must return 403 — the verification that the
# function really is unreachable except through CloudFront. Not a secret:
# the URL grants nothing without a signature.
output "contact_form_function_url" {
  value = aws_lambda_function_url.contact_form.function_url
}

# ------------------------------------------------------------
# Contact form — CloudFront routing
# ADR-012: the browser reaches the function through this distribution at
# /api/contact, never directly. Same origin as the page, so no CORS; and
# the function URL stays invokable by exactly one caller.
# ADR-014: supersedes ADR-007 for this one path only.
# ------------------------------------------------------------

# A second OAC, because an OAC declares the origin type it signs for and
# portfolio_oac above is "s3". Same mechanism as the bucket (ADR-006):
# CloudFront signs every origin request so Lambda can prove it came from
# this distribution rather than from anyone who learned the URL.
resource "aws_cloudfront_origin_access_control" "contact_form_oac" {
  name                              = "portfolio-contact-form-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# A form submission must never be served from cache, and the request body
# must never become part of a cache key.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every viewer header EXCEPT Host, and that exception is what
# makes the whole thing work rather than something being given up. SigV4
# signs the Host header and Lambda validates the signature against its
# OWN hostname — forwarding the viewer's Host: thangkhuat.dev would make
# the signed host and the receiving host disagree, failing every request.
#
# It also carries x-amz-content-sha256 through, which is not optional:
# CloudFront does not hash the request body itself. Per AWS's docs, the
# caller must compute SHA256 of the body and send it in that header,
# because Lambda function URLs don't accept unsigned payloads. CloudFront
# signs whatever value it is handed. Omit it and POST fails with a
# signature mismatch while GET works perfectly — which is exactly what
# makes it hard to diagnose. The browser side of this is in
# assets/contact-form.js.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# The counterpart to authorization_type = "AWS_IAM" on the function URL.
# Until this exists every caller is refused, CloudFront included.
#
# source_arn narrows it to THIS distribution — without that condition the
# grant would let any CloudFront distribution, in any AWS account, invoke
# the function. Same containment as the S3 bucket policy further up.
resource "aws_lambda_permission" "cloudfront_invoke" {
  statement_id           = "AllowCloudFrontServicePrincipal"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.contact_form.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.portfolio_cdn.arn
  function_url_auth_type = "AWS_IAM"
}
