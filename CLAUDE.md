# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform-provisioned AWS infrastructure for a static personal site at `thangkhuat.dev`, plus the
one-page site itself (`index.html`). There is no build step, no test suite, and no application
framework — the deliverable is the infrastructure code and its documented reasoning.

This is an explicit job-hunt portfolio piece. The decision log and inline comments are part of the
product, not overhead: they exist so a reviewer can see *why* each choice was made. Match that
standard when changing things.

## Commands

```bash
terraform init                  # after changing providers or the backend
terraform fmt                   # before committing .tf changes
terraform validate              # syntax + internal consistency, no AWS calls
terraform plan                  # dry run against real AWS state
terraform apply                 # applied locally, never from CI (see below)
terraform output <name>         # e.g. cloudfront_distribution_id, github_actions_role_arn
```

Site content deploys via GitHub Actions on push to `main`, but **only when `index.html` changes** —
the workflow's path filter is that one file. Use **Actions → Deploy to S3 → Run workflow** to
trigger a deploy manually without a throwaway edit.

Diagnosing a failed OIDC assume-role — the STS error deliberately never names the failed condition:

```bash
aws cloudtrail lookup-events --region ap-southeast-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity
```

The `userName` field is the exact `sub` claim GitHub presented. Diff it against the trust policy.

## Architecture

Everything lives in a single `main.tf`, organized in commented sections. Two things about it are
non-obvious from reading any one resource:

**The ACM dependency chain is what makes ordering work.** `aws_acm_certificate` requests a cert,
`aws_route53_record.cert_validation` publishes the DNS proof, and
`aws_acm_certificate_validation` creates nothing — it polls until AWS confirms issuance. CloudFront
references the *validation* resource, not the certificate, and that indirection is the only reason
Terraform waits for validation instead of racing ahead.

**There are two AWS providers.** The default is `ap-southeast-2`; an aliased `aws.us_east_1`
provider exists solely because CloudFront can only find ACM certificates in `us-east-1`. That's a
platform constraint, not a preference.

**Nothing reaches the S3 bucket except CloudFront.** The bucket is fully private with all four
public-access-block flags set. An Origin Access Control signs CloudFront's requests, and the bucket
policy grants `s3:GetObject` only when `AWS:SourceArn` matches this exact distribution.

**CI has its own identity.** GitHub Actions authenticates via OIDC — no AWS keys are stored
anywhere. See "OIDC gotchas" below before touching any of it.

## Conventions

- **Branch and open a PR.** Do not commit directly to `main`. Existing history is PRs #2 onward.
- **No AI attribution in commit messages.** No `Co-Authored-By` trailers of any kind.
- **Record real decisions as ADRs** in `docs/decision-log.md`, numbered, never edited in place —
  supersede with a new entry instead. Include alternatives considered and trade-offs accepted.
- **No hardcoded infrastructure facts in workflows.** Role ARN, bucket name, and distribution ID
  all come from GitHub repository *variables* (not secrets — none of them are credentials). The
  workflow validates they exist before assuming credentials.
- **Keep the AWS account ID out of the repo.** It's public. Docs use `<ACCOUNT_ID>` placeholders.
  GitHub owner/repo IDs are fine — they're public and immutable by design.
- Run `terraform fmt` before committing, but leave unrelated formatting drift alone so diffs stay
  reviewable.

## OIDC gotchas

These cost real debugging time; don't rediscover them.

**The subject claim carries immutable numeric IDs.** GitHub sends
`repo:owner@<owner_id>/repo@<repo_id>:ref:refs/heads/main` — *not* the name-only form that nearly
every published guide shows. `StringEquals` is exact, so the name-only form silently never matches.
Read IDs from `api.github.com/repos/<owner>/<repo>` and `/users/<owner>`.

**The trust policy is pinned to `refs/heads/main`.** A workflow run dispatched from any other branch
is denied *by design*. A denial whose repo/owner segments match and whose ref differs is the control
working, not a bug.

**The `sub` condition is the entire security boundary.** Every Actions run on GitHub can obtain a
valid token, so registering the identity provider proves only "some GitHub workflow." Never loosen
or wildcard that condition.

**No `thumbprint_list` on the OIDC provider, deliberately.** AWS validates the endpoint against its
own CA store; pinning a leaf fingerprint would break on GitHub cert rotation.

## What Terraform deliberately does not manage

Documented in full in `docs/bootstrap.md`. The reasoning matters because it recurs:

- **The inline IAM policy granting Terraform its own OIDC permissions.** `PowerUserAccess` excludes
  IAM, so this is attached by hand. Managing it in Terraform would be circular, and would let
  Terraform rewrite the limits of the identity it runs as — anyone able to run Terraform could then
  grant themselves administrator. The thing that grants privilege stays outside the thing being
  privileged.
- **Nameserver delegation at Porkbun.** Terraform can't drive a third-party registrar. Until this
  is done, `apply` appears to hang on certificate validation.
- **GitHub repository variables.**

## Current state, and one in-flight item

State is **local** (`terraform.tfstate`, gitignored). An S3 state bucket
`thangkhuat-dev-portfolio-tfstate` was created (versioned, encrypted, private) in preparation for a
migration that has **not** happened — there is no `backend` block in `main.tf`. The intended
direction is `terraform plan` in CI on pull requests with a read-only role, while `apply` stays
local, specifically so an IAM-capable credential is never reachable from a git push.

`terraform apply` still runs locally under the `terraform-portfolio` IAM user with
`PowerUserAccess`. ADR-005 records that as a pragmatic starting point, not a final state.

## Docs

- `docs/decision-log.md` — ADRs; read before proposing architectural changes
- `docs/bootstrap.md` — manual setup steps and the order to run them
- `docs/technical-requirements.md` — resource-by-resource breakdown and platform constraints
- `docs/functional-requirements.md`, `docs/session-log.md`, `docs/phase-1-report.md` — scope and history

Note that Phase 2 (VPC/ALB/RDS networking) was built, verified, then destroyed for cost reasons —
ADR-009. It exists only in git history. Don't treat references to it as live infrastructure.
