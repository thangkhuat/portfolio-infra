# Personal Portfolio Site

**Status: Live** at **[thangkhuat.dev](https://thangkhuat.dev)** — infrastructure provisioned entirely with Terraform on AWS.

## Stack

Terraform · AWS (S3, CloudFront, Route 53, ACM, Lambda, SES, DynamoDB, IAM) · GitHub Actions · OIDC · `terraform test`

## Architecture

**The site.** Private S3 bucket served through CloudFront (HTTPS via ACM), with Origin Access Control as the only path allowed into the bucket. DNS resolved through Route 53, domain registered via Porkbun.

**The contact form.** The browser POSTs to `/api/contact` on the same domain — CloudFront routes that one path to a Lambda function URL over a second Origin Access Control, so the function is invokable by this distribution and nothing else. The handler validates, writes the submission to DynamoDB, then sends a notification through SES. Same origin throughout, so no CORS is involved anywhere.

```
browser ──▶ CloudFront ──┬── /*            ──▶ S3 (private, OAC)
                         └── /api/contact  ──▶ Lambda URL (AWS_IAM, OAC)
                                                  ├──▶ DynamoDB
                                                  └──▶ SES
```

## Tests

```bash
terraform test                                   # infrastructure, plan-only
py -m unittest discover -s lambda/contact_form   # the handler
node --test                                      # the browser module
```

No dependencies at any layer. Assertions guarding a security or cost control are verified by mutation — broken deliberately to confirm they can fail — because the first suite reported eleven passing assertions before any had been shown capable of failing. See [ADR-016](docs/decision-log.md).

## Status

- ✅ **Static site** — live, provisioned with Terraform, deployed through GitHub Actions via OIDC.
- ✅ **Contact form** — live. Serverless, so it costs nothing idle; that is why it exists at all, after an earlier ALB-based design was rejected on cost ([ADR-009](docs/decision-log.md), [ADR-011](docs/decision-log.md)).
- 💡 **Known gaps** — listed with reasoning under "Not yet built" in [`docs/technical-requirements.md`](docs/technical-requirements.md).

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