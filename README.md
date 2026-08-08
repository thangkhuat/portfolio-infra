# Personal Portfolio Site

**Status: Complete.** Live at **[thangkhuat.dev](https://thangkhuat.dev)** — infrastructure provisioned entirely with Terraform on AWS.

## Stack

Terraform · AWS (S3, CloudFront, Route 53, ACM) · IAM least-privilege access

## Architecture

Static site → private S3 bucket, served through CloudFront (HTTPS via ACM), with Origin Access Control as the only path allowed into the bucket. DNS resolved through Route 53, domain registered via Porkbun.

## Status

- ✅ **Phase 1 — complete.** Static site live on AWS, provisioned with Terraform. This is the finished project.
- 💡 **Phase 2 onwards — future update.** Dynamic backend, CI/CD, and security hardening are potential future work, not an active roadmap.

## Docs

- [`docs/functional-requirements.md`](docs/functional-requirements.md) — what the site needs to do
- [`docs/technical-requirements.md`](docs/technical-requirements.md) — how it's built
- [`docs/decision-log.md`](docs/decision-log.md) — architecture decisions and reasoning
- [`docs/session-log.md`](docs/session-log.md) — build history, session by session

## Deploy

```bash
terraform init
terraform plan
terraform apply
```

Requires AWS credentials configured locally (`aws configure`) for an IAM user with appropriate permissions.