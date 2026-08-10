# Deploying a Personal Portfolio Site on AWS — Phase 1 Report

**Author:** Thang Khuat
**Live site:** [thangkhuat.dev](https://thangkhuat.dev)
**Repo:** [github.com/thangkhuat/portfolio-infra](https://github.com/thangkhuat/portfolio-infra)

## Overview

Phase 1 of a multi-phase portfolio project: provision a fully custom-domain, HTTPS-secured static site on AWS, entirely through Terraform, with zero manual console configuration. The project doubles as both the job-hunt asset itself and the first concrete piece of a DevOps/cloud portfolio — a CS graduate (Cybersecurity major, Distinction, RMIT) transitioning from five years as a Registered Nurse in anaesthetics into cloud and infrastructure roles.

**Stack:** Terraform · AWS (S3, CloudFront, Route 53, ACM, IAM) · Git/GitHub

## Objective

The goal wasn't just a live website — plenty of free hosting options would achieve that in minutes. The goal was infrastructure that could be explained and defended line by line: real IAM access control, a private storage layer with a single controlled entry point, a validated TLS certificate, and DNS fully managed as code. GitHub Pages was explicitly considered and rejected early on, since it would have removed every piece of AWS infrastructure the project exists to demonstrate.

## Architecture

```
Visitor's browser
      │
      ▼
Route 53 (DNS) ──── resolves thangkhuat.dev to the CloudFront distribution
      │
      ▼
CloudFront (CDN) ─── HTTPS via ACM certificate, edge caching worldwide
      │  (Origin Access Control — signed requests only)
      ▼
S3 bucket ─────────── private, no public access, static files only
```

Every arrow above is a Terraform resource, not a console click: `aws_route53_zone`, `aws_acm_certificate` + `aws_acm_certificate_validation`, `aws_cloudfront_distribution`, `aws_cloudfront_origin_access_control`, `aws_s3_bucket` + its public-access block and policy, and the DNS records tying it together.

## Build Process

1. **Access setup** — a dedicated `terraform-portfolio` IAM user was created (programmatic access only), rather than using root credentials, to contain the blast radius of any future credential leak.
2. **Domain and DNS** — `thangkhuat.dev` registered via Porkbun (cheaper than registering directly through Route 53), with nameservers delegated to a Terraform-managed Route 53 hosted zone.
3. **Storage** — an S3 bucket created fully private, with all four public-access-block flags enabled — no public bucket, no static website hosting feature, by design.
4. **Certificate** — an ACM certificate requested specifically in `us-east-1` (a hard CloudFront/ACM platform requirement, regardless of where other resources live), validated automatically via a Terraform-created DNS record rather than a manual email click.
5. **CDN and access control** — a CloudFront distribution fronts the bucket, using Origin Access Control so the bucket accepts signed requests from this one specific distribution and nothing else — not even a visitor who found the bucket's direct URL.
6. **Content** — a real single-page portfolio (career narrative, skills, this project as a featured case study, experience timeline, contact) replaced the initial test page, deployed via `aws s3 cp` and a CloudFront cache invalidation.
7. **Version control** — the full project, including documentation, pushed to a public GitHub repository, authenticated via a scoped Personal Access Token rather than deprecated password auth.

## Key Decisions

Full reasoning for each lives in `docs/decision-log.md`; summarized here:

- **Terraform over Console/CLI/SDK** — declarative, reviewable, dry-run-able, and the actual tool named in target job postings.
- **Portfolio site as the first project**, not a throwaway demo — every hour invested also produces something to put in front of a recruiter immediately.
- **Full real name as the domain**, not a handle — zero friction matching resume → LinkedIn → portfolio for corporate/cleared-adjacent roles.
- **Private bucket + Origin Access Control**, not S3's built-in static website hosting — the latter requires a public bucket and doesn't support HTTPS on a custom domain at all.
- **No query string or cookie forwarding** in CloudFront's cache behavior — nothing on a static site varies by either, so forwarding them would only hurt cache efficiency for zero benefit.

## Challenges & Lessons Learned

- **The bootstrap problem** — Terraform can't create its own first set of credentials, since it needs credentials to make any API call at all. The very first IAM user had to be created manually; everything downstream of it can be Terraform-managed.
- **Region quirks aren't bugs** — CloudFront's certificate lookup only checking `us-east-1` looks like an inconsistency at first, but it's a documented platform constraint, not something to "fix."
- **Caching isn't optional to understand** — an update can appear to go live without an explicit cache invalidation purely by chance (a cache miss at the serving edge), which is a lucky outcome, not a reliable one. CloudFront's default 24-hour TTL means invalidation is what guarantees a fresh deploy, not a redundant safety step.
- **GitHub's authentication model has changed** — password authentication for Git operations was deprecated in 2021; a Personal Access Token (or SSH key) is required now, a genuinely common first-time stumbling block.
- **Container ≠ small VM** — a conceptually important distinction for anything built in Phase 2 onward: a VM includes a full separate guest OS; a container shares the host's kernel directly, with isolation enforced by the kernel itself rather than hardware-style partitioning.

## Outcome

A live, HTTPS-secured, custom-domain portfolio site, provisioned entirely as code, with:

- Zero manual AWS console configuration for any resource
- A private storage layer with exactly one controlled access path
- Full documentation (README, functional/technical requirements, architecture decision log, session log) committed alongside the infrastructure code
- A public GitHub repository demonstrating the actual Terraform, not just the result

## Status: Phase 1 complete

> **Later addendum.** This report describes Phase 1 as it stood when written, and is kept as a
> point-in-time record rather than being revised. The site has since gained a serverless contact
> form — Lambda, SES and DynamoDB behind the same CloudFront distribution — which reversed the
> scope call below without contradicting its cost reasoning. See ADR-011 through ADR-016 in
> `docs/decision-log.md`, and `docs/technical-requirements.md` for the current architecture.

Phase 1 itself is finished — live, documented, and stable.

**Phase 2 onwards is a future update**, not an active roadmap. A dynamic-backend network layer was built and confirmed working after this report was first written, then deliberately torn down — the ongoing cost of an Application Load Balancer (~$16–22/month, no free tier at any account age) wasn't justified without real traffic or revenue. Full working Terraform remains in Git history. See `docs/decision-log.md` (ADR-009) for the full reasoning.
