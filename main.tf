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
