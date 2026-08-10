# Personal Portfolio Site

**Status: Complete.** Live at **[thangkhuat.dev](https://thangkhuat.dev)** — infrastructure provisioned entirely with Terraform on AWS.

## Stack

Terraform · AWS (S3, CloudFront, Route 53, ACM) · GitHub Actions · IAM least-privilege access · `terraform test`

## Architecture

Static site → private S3 bucket, served through CloudFront (HTTPS via ACM), with Origin Access Control as the only path allowed into the bucket. DNS resolved through Route 53, domain registered via Porkbun.

## Status

- ✅ **Phase 1 — complete.** Static site live on AWS, provisioned with Terraform. This is the finished project.
- 💡 **Phase 2 onwards — future update.** Dynamic backend, CI/CD, and security hardening are potential future work, not an active roadmap.

## Docs

- [`docs/bootstrap.md`](docs/bootstrap.md) — the manual steps Terraform deliberately doesn't own, and why
- [`docs/functional-requirements.md`](docs/functional-requirements.md) — what the site needs to do
- [`docs/technical-requirements.md`](docs/technical-requirements.md) — how it's built
- [`docs/decision-log.md`](docs/decision-log.md) — architecture decisions and reasoning

## Deploy

```bash
terraform init
terraform test     # plan-only assertions on the security and cost controls; creates nothing
terraform plan
terraform apply
```

Requires AWS credentials configured locally (`aws configure`) for an IAM user with appropriate permissions. A rebuild from an empty AWS account needs the one-time manual steps in [`docs/bootstrap.md`](docs/bootstrap.md) first — `terraform apply` alone is not sufficient.

Site content deploys automatically: a push to `main` triggers GitHub Actions, which uploads to S3 and invalidates the CloudFront cache. No AWS access keys are stored in the repo — the workflow authenticates via OIDC, exchanging a short-lived GitHub-signed token for temporary credentials scoped to exactly two actions. See [ADR-010](docs/decision-log.md).