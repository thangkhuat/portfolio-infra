# Decision Log — Personal Portfolio Site

Architecture Decision Records (ADRs) for this project. Each entry captures a choice, the alternatives considered, and the reasoning — not just what was built, but why. Add a new numbered entry whenever a real decision gets made; don't edit past entries, supersede them with a new one if a decision later changes.

---

### ADR-001 — Use Terraform for infrastructure provisioning
**Status:** Accepted

**Context:** Needed to provision S3, CloudFront, Route 53, and ACM resources for the site.

**Alternatives considered:**
- AWS Console (manual clicking)
- AWS CLI (scripted, but imperative — action-based, not state-based)
- AWS SDK / boto3 (built for application runtime calls, not infra provisioning)

**Decision:** Terraform.

**Reasoning:** Declarative rather than imperative — describe the end state, let Terraform figure out the steps. `plan` gives a dry-run before anything real changes. State tracking means it knows exactly what exists without guessing. Produces an actual reviewable code artifact for the portfolio, rather than leaving zero trace like console clicks would. Matches the tool named directly in the DevOps/cloud job postings being targeted.

**Trade-offs accepted:** Steeper learning curve than clicking through a UI; HCL syntax and Terraform-specific concepts (state, providers, lifecycle) had to be learned from scratch.

---

### ADR-002 — Personal portfolio/blog site as the first infrastructure project
**Status:** Accepted

**Context:** Needed an application to build real infrastructure around.

**Alternatives considered:** URL shortener API (simpler, more "textbook" infra demo); task/notes app with auth (adds an early security angle).

**Decision:** Personal portfolio/blog site.

**Reasoning:** Doubles as the actual job-hunt asset — every hour spent also produces something to put on a resume immediately, rather than a throwaway demo. Still requires the same infra depth (VPC/EC2/RDS planned for Phase 2) once the dynamic backend is added.

**Trade-offs accepted:** Slightly less "generic" as a teaching example than a pure API project — but the real-world utility outweighs that for a job-hunt timeline.

---

### ADR-003 — Domain via Porkbun + Route 53 hosted zone, not GitHub Pages or Route 53 registration
**Status:** Accepted

**Context:** Needed a domain name and a hosting path.

**Alternatives considered:**
- Register directly through Route 53 (simpler, one vendor, but pricier)
- Free `thangkhuat.github.io` via GitHub Pages (zero cost, but zero AWS involvement)

**Decision:** Register the domain cheaply via Porkbun, delegate DNS to a Route 53 hosted zone.

**Reasoning:** Porkbun is meaningfully cheaper than registering the same domain through Route 53 directly. GitHub Pages was rejected outright — it would remove S3, CloudFront, and ACM from the picture entirely, defeating the actual purpose of the project (demonstrating AWS/Terraform skill for DevOps roles).

**Trade-offs accepted:** Nameserver delegation is a one-time manual step in Porkbun's dashboard — Terraform can't automate registration or delegation with a third-party registrar, only everything after that.

---

### ADR-004 — Domain uses full real name, not a handle
**Status:** Accepted

**Decision:** `thangkhuat.dev`, matching "Thang Khuat" exactly as it appears on LinkedIn and the resume.

**Reasoning:** For corporate DevOps/cleared-adjacent roles, a recruiter matching resume → LinkedIn → portfolio should hit zero friction. A handle or alias is more relevant for independent CTF/bug-bounty reputation building, not this track. `.dev` also happens to force HTTPS via browser preload — a small, genuine talking point for a security-conscious build.

---

### ADR-005 — Dedicated IAM user for Terraform, not root credentials
**Status:** Accepted (policy scope intentionally broad for now)

**Context:** Terraform needs AWS credentials to authenticate.

**Alternatives considered:** Using root account credentials directly.

**Decision:** Created `terraform-portfolio`, a dedicated IAM user, programmatic access only, `PowerUserAccess` policy.

**Reasoning:** Root has unlimited account power — billing, deletion, everything. A dedicated user contains the blast radius if credentials ever leak, and can be revoked or rotated independently of the actual account login. Least privilege principle.

**Trade-offs accepted:** `PowerUserAccess` is still broader than ideal — chosen as a pragmatic starting point to avoid fighting permissions errors mid-build, not as a final state. Will be narrowed to a custom least-privilege policy in Phase 4.

---

### ADR-006 — Private S3 bucket + CloudFront OAC, not S3 static website hosting
**Status:** Accepted

**Context:** Needed to serve static files publicly.

**Alternatives considered:** S3's built-in "static website hosting" feature.

**Decision:** Keep the bucket fully private; front it with CloudFront using Origin Access Control (OAC).

**Reasoning:** S3 static website hosting requires the bucket to be fully public and only serves plain HTTP — no HTTPS on a custom domain without a CDN anyway. OAC keeps exactly one controlled entry point (CloudFront) and blocks every other path to the bucket, including someone guessing the direct S3 URL. Directly supports the DevSecOps-leaning story for the portfolio.

**Trade-offs accepted:** More resources to configure (OAC + a JSON bucket policy) versus flipping one checkbox — accepted as the cost of doing it securely.

---

### ADR-007 — No query string or cookie forwarding in CloudFront cache behavior
**Status:** Accepted (revisit in Phase 2)

**Decision:** `forwarded_values.query_string = false`, `cookies.forward = "none"`.

**Reasoning:** Nothing on a static site varies by query string or cookie, so forwarding either would only hurt the cache hit rate for zero benefit — every visitor can safely share the same cached response.

**Will change when:** Phase 2 adds a dynamic backend (e.g., a contact form or session-aware content) that genuinely needs specific data forwarded to the origin.

---

### ADR-008 — No geographic restriction
**Status:** Accepted

**Decision:** `geo_restriction.restriction_type = "none"`.

**Reasoning:** The audience is recruiters and hiring managers globally — no legal or business reason to block any region.

---

### ADR-009 — Stop at Phase 1; build, verify, then tear down Phase 2
**Status:** Accepted

**Context:** Phase 2 (VPC, subnets, security groups, ALB, RDS-ready networking) was fully built and confirmed working end-to-end, routing `/api/*` through CloudFront to a live ALB. Compute and RDS were the only pieces left before it would incur its full ongoing cost.

**Alternatives considered:**
- Deploy compute + RDS and keep the whole stack running continuously
- Deploy compute + RDS but only run it during active job-hunting/demo periods

**Decision:** Destroy all 26 Phase 2 resources. Declare Phase 1 the complete, live project. Treat Phase 2's revised scope (serving the project list dynamically from a database) as a documented but unstarted potential feature, not an active roadmap item.

**Reasoning:** The ALB alone costs ~$16–22/month with zero free-tier coverage, regardless of traffic — a fixed cost with no revenue or real usage to justify it right now. The original Phase 2 purpose (contact form, blog) was also reconsidered as genuinely unnecessary for this site. Keeping the built-but-unused infrastructure running would be paying to demonstrate a skill that's already been demonstrated and documented — the working code and this decision log serve that purpose without the ongoing cost.

**Trade-offs accepted:** Resuming later means rebuilding the VPC/subnet/security-group layer from scratch (all 26 resources were destroyed, not just the compute/RDS pieces) — accepted since none of it cost anything to leave running, but wasn't preserved due to how the teardown was scoped. Full working Terraform for this layer remains in Git history regardless.

---

### ADR-010 — GitHub Actions authenticates to AWS via OIDC, not static access keys
**Status:** Accepted (partially supersedes the deploy-path half of ADR-005)

**Context:** The deploy workflow pushed `index.html` to S3 using `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` stored as GitHub secrets. Those are long-lived credentials — they don't expire, weren't being rotated, and stay valid from anywhere until manually revoked. A leak via a compromised third-party action, a log dump, or anyone with repo admin would hand over whatever that IAM user could do, indefinitely.

**Alternatives considered:**
- Keep the IAM user, add a rotation schedule — reduces the exposure window but never closes it; still a standing credential
- A second, deploy-only IAM user with a narrow policy — fixes the blast radius but not the "long-lived secret sitting in GitHub" problem

**Decision:** Register GitHub's OIDC issuer as an identity provider in the AWS account and create `github-actions-portfolio-deploy`, a role the workflow assumes via `sts:AssumeRoleWithWebIdentity`. Trust policy asserts both `aud = sts.amazonaws.com` and `sub = repo:thangkhuat/portfolio-infra:ref:refs/heads/main`. Permissions scoped to `s3:PutObject` on the site bucket and `cloudfront:CreateInvalidation` on the one distribution.

**Reasoning:** Removes the stored credential entirely rather than shortening its life — GitHub mints a signed token per run asserting which repo and branch is executing, AWS trades it for credentials valid about an hour. The `sub` condition is the real security boundary: every Actions run on GitHub can obtain a valid token, so the identity provider alone proves only "some GitHub workflow," not this one. Omitting or wildcarding that claim is the well-known misconfiguration that leaves a role assumable from any repository on GitHub. The two-action policy also delivers, for the deploy path specifically, the least-privilege narrowing ADR-005 deferred to Phase 4 — worst case on compromise is site defacement, with no read, delete, or lateral access.

The role ARN is stored as a GitHub *variable* rather than a secret. An ARN is an identifier, not a credential; holding it grants nothing, since the trust policy gates access. Filing a non-secret in the secrets store would misrepresent what a secret is.

**Implementation note — the `sub` claim format:** GitHub issues *immutable* subject claims, with owner and repo IDs appended, rather than the name-only form nearly every OIDC guide still shows:

```
repo:thangkhuat@177017208/portfolio-infra@1322692264:ref:refs/heads/main   # actual
repo:thangkhuat/portfolio-infra:ref:refs/heads/main                       # what the guides show
```

The first deploy failed on this. `StringEquals` is exact, so the condition never matched. Matching the numeric form is strictly stronger anyway: names are mutable — a repo can be renamed, and a deleted account's username can be re-registered by someone else, either of which would let a name-based policy authorize an impostor. Owner and repo IDs are never reassigned.

AWS keeps the STS error deliberately vague (`Not authorized to perform sts:AssumeRoleWithWebIdentity`) because naming the failed condition would leak policy contents to an unauthenticated caller. CloudTrail records the claim that was actually presented:

```bash
aws cloudtrail lookup-events --region ap-southeast-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity
```

The `userName` field is the exact `sub` GitHub sent — diff it against the trust policy.

**Verified, not just designed:** a `workflow_dispatch` run from the `fix-oidc-immutable-sub` branch was denied, with CloudTrail showing the owner/repo portion matching and only `ref:refs/heads/fix-oidc-immutable-sub` differing. The branch restriction is therefore confirmed enforced, not merely configured. The same run from `main` succeeded.

**Trade-offs accepted:** The trust policy is pinned to `refs/heads/main`, so deploying from any other branch requires a deliberate policy edit — intentional friction, not an oversight. Setup is also more involved than pasting two keys: an identity provider, a role, a trust policy, and the `id-token: write` job permission all have to be right before the first deploy works. `terraform apply` itself still runs locally under the `terraform-portfolio` IAM user from ADR-005 — this decision covers the CI deploy path only. Moving Terraform to OIDC as well would require remote state first, and remains open.