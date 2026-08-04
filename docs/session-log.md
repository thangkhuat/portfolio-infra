# Session Log — Personal Portfolio Project

One entry per working session: what was covered conceptually, what was actually built, decisions made, and what's still open. Add a new entry at the top for each future session.

---

## Session 1 — 2 Aug 2026

### Conceptual coverage
- Terraform fundamentals: declarative vs. imperative, why `plan` before `apply` matters (irreversible actions like bucket destroy/recreate)
- IAM least privilege — why not to use root credentials for Terraform
- S3: object storage vs. a traditional running server; why static hosting doesn't need one
- CloudFront: edge caching, cache hit vs. miss, why a fixed IP can't represent a global CDN
- Route 53: DNS resolution, alias records vs. normal A records, one-time-only role per request (doesn't sit in the return path)
- ACM certificates: asymmetric crypto (public/private key), CA trust chain, what's inside a signed cert, the DNS validation record mechanism
- Full TLS handshake: TCP → ClientHello (+ SNI) → ServerHello + cert → pre-master secret → session key
- CloudFront distribution resource anatomy: `origin`, `default_cache_behavior` (+ `forwarded_values`/`cookies`), `restrictions`, `viewer_certificate`
- S3 bucket policy structure; OAC vs. making the bucket public; SigV4 (symmetric/HMAC) vs. TLS (asymmetric) — different mechanisms, don't conflate
- Why the `portfolio_alias` record specifically is what makes the domain resolve at all

### What was built
- Terraform installed, added to PATH
- `terraform-portfolio` IAM user created (PowerUserAccess, programmatic access only)
- AWS CLI installed and configured locally
- Project scaffolded at `C:\Users\huuth\OneDrive\Desktop\Personal_Page` (Git repo, `.gitignore` in place before any real files)
- Domain `thangkhuat.dev` registered via Porkbun, nameservers delegated to Route 53
- Terraform resources created (all in `main.tf`):
  - `aws_route53_zone.portfolio`
  - `aws_s3_bucket.portfolio_site` + `aws_s3_bucket_public_access_block`
  - `aws_acm_certificate.portfolio_cert` + `aws_acm_certificate_validation` (us-east-1)
  - `aws_route53_record.cert_validation`
  - `aws_cloudfront_origin_access_control.portfolio_oac`
  - `aws_cloudfront_distribution.portfolio_cdn`
  - `aws_s3_bucket_policy.portfolio_site`
  - `aws_route53_record.portfolio_alias`
- Test `index.html` uploaded to S3, confirmed live and working at `https://thangkhuat.dev`

### Decisions made
- AWS chosen over Azure/GCP — most in-demand, keeps cleared/private-sector tracks both open
- Portfolio/blog site chosen as Project 1 theme over a throwaway app — doubles as the actual job-hunt asset
- Domain uses full name (`thangkhuat.dev`), not a handle — matches LinkedIn/resume exactly, no ambiguity for recruiters
- Registered via Porkbun + hosted on AWS — rejected GitHub Pages, since it would remove all the AWS/Terraform infrastructure this project exists to demonstrate

### Open items / next steps
- **Process change starting next session:** read the Terraform Registry docs for a resource together before writing it, rather than being handed finished code
- Consider switching CloudFront to `PriceClass_100` (cost saving, NA/EU only)
- Replace test `index.html` with real site content
- Write the repo README / case-study write-up
- Formal Phase 1 post-phase quiz — mostly resolved through discussion, but worth a clean re-quiz next session covering: plan vs. apply risk, the 3-resource cert chain, Route 53's one-time role, and today's CloudFront resource breakdown
- Not urgent yet, but flag before Phase 2: local Terraform state is fine solo — revisit remote state if working from multiple machines later

---

## Session 2 — 4 Aug 2026

### Conceptual coverage
- CloudFront TTL / cache expiry — `default_ttl` (86400s / 24h default, since S3 origin sends no `Cache-Control` header), how it differs from `min_ttl`/`max_ttl`, and how `create-invalidation` overrides the clock rather than being a separate mechanism
- Route 53's one-time-per-lookup role re-confirmed via quiz (fresh domain lookup only, not per-page or per-request)
- Why Terraform couldn't have created the `terraform-portfolio` IAM user itself — the bootstrap problem (no credentials to authenticate the very first API call) plus the state-file-secrets risk of `aws_iam_access_key`

### What was built
- Real site content designed and deployed, replacing the Phase 1 test page — single-page portfolio (hero, pivot narrative, skills, featured project, experience timeline, contact), light clinical-precision palette, IBM Plex Mono/Sans, signature waveform trace marking the nursing→tech career pivot
- Deployed via `aws s3 cp` + `aws cloudfront create-invalidation`, confirmed live
- Added `cloudfront_distribution_id` Terraform output, annotated with reasoning (needed for invalidation; pull live via `terraform output`, never hardcode — ID would go stale if the distribution is ever recreated)
- Full inline comments added to `main.tf`, matching the actual file's resource order, cross-referencing ADR numbers from `decision-log.md`
- Created `README.md` (short, links out to `docs/`) and moved `functional-requirements.md`, `technical-requirements.md`, `decision-log.md`, `session-log.md` into a `docs/` folder

### Decisions made
- Citizenship line removed from the public site's contact section — kept for direct conversations/applications where it's actually asked for, not left on a page anyone can find
- CloudFront price class decision explicitly deferred — flagged as low-stakes given free-tier traffic volume, not worth optimizing prematurely

### Open items / next steps
- Push the project to an actual GitHub repo — the site's own "View the code on GitHub" link currently points at the GitHub profile as a placeholder
- Add graduation date to the site's timeline (currently unspecified)
- Move to Phase 2 pre-quiz (dynamic backend: VPC, compute, RDS) when ready
