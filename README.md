# Personal Portfolio Site

Live at [**thangkhuat.dev**](https://thangkhuat.dev) — infrastructure provisioned entirely with Terraform on AWS.

## Stack

Terraform · AWS (S3, CloudFront, Route 53, ACM) · IAM least-privilege access

## Architecture

Static site → private S3 bucket, served through CloudFront (HTTPS via ACM), with Origin Access Control as the only path allowed into the bucket. DNS resolved through Route 53, domain registered via Porkbun.

## Status

- ✅ **Phase 1** — Static site live on AWS, provisioned with Terraform  
- ⬜ Phase 2 — Dynamic backend (VPC, compute, RDS)  
- ⬜ Phase 3 — CI/CD pipeline (GitHub Actions)  
- ⬜ Phase 4 — Security hardening (least-privilege IAM, Secrets Manager, GuardDuty)

## Docs

- [`docs/functional-requirements.md`](http://docs/functional-requirements.md) — what the site needs to do  
- [`docs/technical-requirements.md`](http://docs/technical-requirements.md) — how it's built  
- [`docs/decision-log.md`](http://docs/decision-log.md) — architecture decisions and reasoning  
- [`docs/session-log.md`](http://docs/session-log.md) — build history, session by session

## Deploy

terraform init

terraform plan

terraform apply

Requires AWS credentials configured locally (`aws configure`) for an IAM user with appropriate permissions.  
