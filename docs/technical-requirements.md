# Technical Requirements — Personal Portfolio Site

How the site is actually built. This is the implementation detail behind functional-requirements.md.

**Currently deployed: the static site and the contact form.** Everything below is live in AWS. The
VPC/ALB network layer explored under the old "Phase 2" label was built, verified, then torn down —
see the note at the bottom.

## Stack

- **IaC:** Terraform, `hashicorp/aws` provider `~> 5.0`
- **Cloud:** AWS
- **Primary region:** `ap-southeast-2` (Sydney)
- **Secondary region:** `us-east-1` — required only because CloudFront's ACM certificate lookup is hardcoded to this region regardless of where other resources live

## Infrastructure Components (static site — live)

| Resource | Purpose |
|----------|---------|
| `aws_s3_bucket` | Static file storage. Fully private. |
| `aws_s3_bucket_public_access_block` | All 4 flags set `true` — blocks public access even if a policy/ACL is later misconfigured |
| `aws_route53_zone` | DNS hosted zone for `thangkhuat.dev` |
| `aws_acm_certificate` + `aws_acm_certificate_validation` | DNS-validated TLS cert, requested in `us-east-1` |
| `aws_route53_record` (`cert_validation`) | Auto-created CNAME proving domain ownership to ACM |
| `aws_cloudfront_origin_access_control` | Signed identity — only this specific CloudFront distribution may read the bucket |
| `aws_cloudfront_distribution` | CDN. HTTPS-only, GET/HEAD only. `price_class = PriceClass_All` (default — consider `PriceClass_100` to cut cost, since recruiters are mostly NA/EU) |
| `aws_s3_bucket_policy` | Grants `s3:GetObject` only to the specific CloudFront distribution ARN, via OAC |
| `aws_route53_record` (`portfolio_alias`) | Alias record mapping `thangkhuat.dev` → the CloudFront distribution |

## Infrastructure Components (contact form — live)

Browser → CloudFront `/api/contact` → Lambda function URL → DynamoDB + SES. Same origin as the
page, so no CORS is involved anywhere. See ADR-011 through ADR-015.

| Resource | Purpose |
|----------|---------|
| `aws_dynamodb_table` | Submission store. On-demand billing, UUID partition key, KMS encryption, point-in-time recovery, deletion protection |
| `aws_lambda_function` | Python 3.12 handler. Validates, persists, then notifies. Zipped from one dependency-free file by `archive_file` |
| `aws_lambda_function_url` | `authorization_type = "AWS_IAM"` — every request must be SigV4-signed. No CORS block, deliberately |
| `aws_lambda_permission` ×2 | `InvokeFunctionUrl` **and** `InvokeFunction`, both pinned to this distribution's ARN. Both are required |
| `aws_iam_role` + `aws_iam_role_policy` | Execution role, hand-scoped: `PutItem` only, `SendEmail` conditioned on `ses:FromAddress`, logs to one group |
| `aws_cloudwatch_log_group` | Declared explicitly with 14-day retention — Lambda would otherwise auto-create it as never-expiring |
| `aws_cloudfront_origin_access_control` (`contact_form_oac`) | Second OAC, origin type `lambda`. Signs CloudFront's requests to the function |
| `ordered_cache_behavior` on `/api/contact` | Managed `CachingDisabled` + `AllViewerExceptHostHeader`. `https-only`, not `redirect-to-https` |
| `aws_ses_domain_identity` + `aws_ses_domain_dkim` | Sending identity for `thangkhuat.dev`, with three DKIM CNAMEs |
| `aws_ses_domain_identity_verification` | Creates nothing; polls until SES confirms. Same indirection as the ACM chain |
| `aws_ses_email_identity` | The notification recipient. Required because the account stays in the SES sandbox |
| `aws_route53_record` (`ses_verification`, `ses_dkim` ×3) | TXT proof of domain ownership, plus the DKIM CNAMEs |

## Testing

| Layer | Tool | Location |
|-------|------|----------|
| Terraform | `terraform test` | `tests/*.tftest.hcl` — plan-only, creates nothing, needs AWS credentials |
| Lambda handler | stdlib `unittest` | `lambda/contact_form/test_handler.py` — run with `-s lambda/contact_form` |
| Browser module | `node --test` | `assets/contact-form.test.js` |

No dependencies at any layer: `node --test` ships with Node 18+, `unittest` is stdlib, and boto3 is
stubbed rather than installed. Assertions guarding a security or cost control are mutation-verified —
see ADR-016.

## Access & Credentials

- IAM user: `terraform-portfolio` — programmatic access only, no console login
- Current policy: `PowerUserAccess` (**temporary** — would be replaced with a least-privilege custom policy if Phase 4 is ever taken up)
- AWS CLI configured locally via `aws configure`; credentials live at `~/.aws/credentials`, never committed
- Domain registrar: Porkbun (`thangkhuat.dev`); nameservers delegated to Route 53

## Version Control

- Repo location: `C:\Users\huuth\OneDrive\Desktop\portfolio-infra`
- `.gitignore` excludes: `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`, `build/`,
  `__pycache__/`, `node_modules/`, `docs/session-log.md`, `CLAUDE.md`
- `.terraform.lock.hcl` **is** committed — pins the exact provider versions for reproducibility
- `build/contact_form.zip` is a derived artifact, rebuilt by `archive_file` on every plan; the `.py`
  file is the source of truth
- `docs/session-log.md` and `CLAUDE.md` are kept on disk as working notes and local tooling
  guidance, deliberately not part of the published project

## State Management

- Currently: local `.tfstate` file (default, fine for solo work on one machine)
- Worth reconsidering only if this project is resumed and grows to multi-machine work

## Known Platform Constraints

- ACM certificates used by CloudFront must be requested in `us-east-1`, regardless of where every other resource lives — a CloudFront/ACM platform requirement, not a design choice
- ACM certificates used by an ALB must be requested in the ALB's *own* region instead — a separate, regional requirement, discovered when Phase 2's listener failed against the `us-east-1` cert
- S3 bucket names must be globally unique across *all* AWS accounts, not just yours
- **CloudFront does not hash the request body for a Lambda function URL origin.** The caller must compute `SHA-256(body)` and send it as `x-amz-content-sha256`; CloudFront signs whatever value it is handed. Omitting it fails every POST on signature validation while GET keeps working, since a GET has no body to hash. See ADR-012
- **A Lambda function URL behind OAC needs two grants, not one** — `lambda:InvokeFunctionUrl` *and* `lambda:InvokeFunction`. AWS's documentation lists both; the second is not redundant, and omitting it returns `403 AccessDeniedException` on an otherwise correct request
- **`AllViewerExceptHostHeader` is required, not merely recommended.** SigV4 signs `Host` and Lambda validates against its own hostname, so forwarding the viewer's `Host` breaks every request
- **SES authorizes `ses:SendEmail` against every identity in the call, not just the sender.** While the account stays in the sandbox the recipient is a verified identity too, so its ARN must appear in the IAM policy alongside the sending domain's. See ADR-013
- **New AWS accounts start at a Lambda concurrency limit of 10, not 1000**, and the required unreserved minimum is also 10 — so `reserved_concurrent_executions` cannot be set at any value until the quota is raised. See ADR-015
- **`for_each` cannot iterate a value that is unknown until apply**, because it must know its keys during graph construction. The SES DKIM records use `count = 3` for this reason, accepting positional keying as the cost
- SES is available in `ap-southeast-2`, so no second provider alias is needed for it — unlike ACM/CloudFront

## Cost

Steady state is effectively zero. Lambda and DynamoDB on-demand both sit inside the always-free
tier at this volume; SES is $0.10 per thousand messages and capped at 200/day by the sandbox;
CloudFront and Route 53 request charges are negligible. The only fixed costs are the domain
registration and the Route 53 hosted zone. This is the whole reason the contact form passes the
cost test that the ALB failed — see ADR-009 and ADR-011.

## The VPC/ALB layer — built, verified, torn down

A full network layer (VPC, 4 subnets, security groups, ALB, regional ACM cert, CloudFront path
routing) was built and confirmed working, then torn down before compute or RDS were added — the
ALB's ~$16–22/month fixed cost (no free tier at any account age) wasn't justified without real
traffic or revenue. Full working code remains in Git history. See `docs/decision-log.md` (ADR-009).

Note that the contact form did *not* revive this. It reaches the same goal serverlessly, which is
why ADR-011 supersedes ADR-009's scope call without contradicting its cost reasoning.

## Not yet built

- A CloudWatch alarm on the Lambda error metric. A failing SES send returns 200 to the visitor by
  design, since the submission is stored — which means a broken mail path is invisible without one.
  This was found the hard way; see ADR-013
- Per-IP rate limiting, deferred rather than dismissed (ADR-015)
- A custom MAIL FROM domain for tighter SPF/DMARC alignment
- Migrating the default cache behavior off legacy `forwarded_values` onto cache policies (ADR-014)
- A least-privilege replacement for `PowerUserAccess` on the Terraform user (ADR-005)