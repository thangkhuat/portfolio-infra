# Technical Requirements — Personal Portfolio Site

How the site is actually built. This is the implementation detail behind functional-requirements.md.

## Stack

- **IaC:** Terraform, `hashicorp/aws` provider `~> 5.0`  
- **Cloud:** AWS  
- **Primary region:** `ap-southeast-2` (Sydney)  
- **Secondary region:** `us-east-1` — required only because CloudFront's ACM certificate lookup is hardcoded to this region regardless of where other resources live

## Infrastructure Components (Phase 1\)

| Resource | Purpose |
| :---- | :---- |
| `aws_s3_bucket` | Static file storage. Fully private. |
| `aws_s3_bucket_public_access_block` | All 4 flags set `true` — blocks public access even if a policy/ACL is later misconfigured |
| `aws_route53_zone` | DNS hosted zone for `thangkhuat.dev` |
| `aws_acm_certificate` \+ `aws_acm_certificate_validation` | DNS-validated TLS cert, requested in `us-east-1` |
| `aws_route53_record` (`cert_validation`) | Auto-created CNAME proving domain ownership to ACM |
| `aws_cloudfront_origin_access_control` | Signed identity — only this specific CloudFront distribution may read the bucket |
| `aws_cloudfront_distribution` | CDN. HTTPS-only, GET/HEAD only. `price_class = PriceClass_All` (default — consider `PriceClass_100` to cut cost, since recruiters are mostly NA/EU) |
| `aws_s3_bucket_policy` | Grants `s3:GetObject` only to the specific CloudFront distribution ARN, via OAC |
| `aws_route53_record` (`portfolio_alias`) | Alias record mapping `thangkhuat.dev` → the CloudFront distribution |

## Access & Credentials

- IAM user: `terraform-portfolio` — programmatic access only, no console login  
- Current policy: `PowerUserAccess` (**temporary** — replace with a least-privilege custom policy in Phase 4\)  
- AWS CLI configured locally via `aws configure`; credentials live at `~/.aws/credentials`, never committed  
- Domain registrar: Porkbun (`thangkhuat.dev`); nameservers delegated to Route 53

## Version Control

- Repo location: `C:\Users\huuth\OneDrive\Desktop\Personal_Page`  
- `.gitignore` excludes: `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`  
- `.terraform.lock.hcl` **is** committed — pins the exact provider version for reproducibility

## State Management

- Currently: local `.tfstate` file (default, fine for solo work on one machine)  
- **Revisit before Phase 2:** consider a remote backend (S3 \+ DynamoDB locking) if working from more than one machine or once state file loss would be costly

## Known Platform Constraints

- ACM certificates used by CloudFront must be requested in `us-east-1`, regardless of where every other resource lives — a CloudFront/ACM platform requirement, not a design choice  
- S3 bucket names must be globally unique across *all* AWS accounts, not just yours

