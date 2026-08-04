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
