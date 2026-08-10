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

**Bootstrap left outside Terraform, deliberately:** `PowerUserAccess` excludes IAM, so Terraform needs an additional inline policy on its own IAM user before it can create any of the above. That policy is applied by hand in the console and is *not* managed by Terraform. Managing it there would be circular — the permission would be required before it could be created, deadlocking a fresh account — and would let Terraform rewrite the limits of the identity it runs as, meaning anyone able to run Terraform, or holding its credentials or state, could grant themselves administrator. The thing that grants privilege stays outside the thing being privileged. The policy, and every other manual step, is recorded in [`bootstrap.md`](bootstrap.md).

**Trade-offs accepted:** The trust policy is pinned to `refs/heads/main`, so deploying from any other branch requires a deliberate policy edit — intentional friction, not an oversight. Setup is also more involved than pasting two keys: an identity provider, a role, a trust policy, and the `id-token: write` job permission all have to be right before the first deploy works. `terraform apply` itself still runs locally under the `terraform-portfolio` IAM user from ADR-005 — this decision covers the CI deploy path only. Moving Terraform to OIDC as well would require remote state first, and remains open.

---

### ADR-011 — Contact form on Lambda + SES + DynamoDB, not a rebuilt ALB stack
**Status:** Accepted (supersedes the scope half of ADR-009)

**Context:** The only way to reach the site owner was a `mailto:` link, which publishes a personal address to scrapers and gives a visiting recruiter no in-page path to make contact. ADR-009 had considered a contact form and dismissed it as "genuinely unnecessary," but that judgement was made while the only design on the table was the Phase 2 ALB stack.

**Alternatives considered:**
- Rebuild Phase 2's VPC/ALB layer and run the form behind it (the design ADR-009 was actually rejecting)
- A third-party form service such as Formspree (fastest, but removes the AWS work this project exists to demonstrate, and hands submissions to someone else)
- Keep `mailto:` only

**Decision:** Build it serverless — an API on a Lambda function URL, submissions persisted to DynamoDB, notification sent through SES.

**Reasoning:** ADR-009's reasoning was about cost, not about the feature. An ALB bills ~$16–22/month whether or not anyone submits anything; that fixed cost with no traffic was what failed the test. Every component chosen here bills per use and costs nothing idle: Lambda and DynamoDB on-demand both sit inside the always-free tier at this volume, and SES is $0.10 per thousand messages. The same test applied to a different design gives the opposite answer, which is why this reverses the scope call without contradicting the reasoning behind it.

Persisting to DynamoDB as well as emailing is deliberate redundancy. The email is the thing that gets read; the table is the thing that means a submission is never lost to a transient SES failure, a spam filter, or a deleted message.

**Trade-offs accepted:** More moving parts than a `mailto:` link — a function, an execution role, a table, two SES identities, DNS records, and a CloudFront behavior, each of which can fail independently. Three of them did on first apply (see ADR-013 and ADR-015). Accepted because the alternative was either no feature or a monthly bill.

---

### ADR-012 — CloudFront-fronted, OAC-signed function URL, not a public one with CORS
**Status:** Accepted

**Context:** A Lambda function URL needs to be reachable from the browser. The obvious route is `authorization_type = "NONE"` plus a CORS configuration allowing the site's origin.

**Alternatives considered:**
- Public function URL (`NONE`) with CORS — about five fewer resources
- API Gateway HTTP API in front of the function, optionally with its own subdomain and certificate

**Decision:** Route `/api/contact` through the existing CloudFront distribution to a function URL set to `AWS_IAM`, signed by a second Origin Access Control, with a resource policy naming this one distribution.

**Reasoning:** `NONE` means invokable by anyone on the internet who learns the URL — and the URL would appear in page source the moment the form shipped, so "who learns it" is everyone. CORS does not help: it is a browser-enforced policy about who may *read a response*, not a control over who may *call the endpoint*. `curl` ignores it entirely.

Routing through CloudFront also makes the request same-origin, so CORS never enters into it at all, and keeps the `*.lambda-url.on.aws` hostname out of the page. It is the same containment shape already used for the S3 bucket in ADR-006 — one controlled entry point, everything else refused — applied a second time, which is worth more than the resources it costs.

API Gateway was rejected as a second edge service in front of an edge service that already exists, for throttling and access logs this project does not need.

**Implementation note — CloudFront does not hash the request body.** This is the detail that costs an evening. AWS's documentation is explicit:

> If you use `PUT` or `POST` methods with your Lambda function URL, your users must compute the SHA256 of the body and include the payload hash value of the request body in the `x-amz-content-sha256` header when sending the request to CloudFront. Lambda doesn't support unsigned payloads.

"Your users" means the browser. CloudFront signs whatever value it is handed; Lambda hashes what it actually received and compares. Omit the header and every POST fails signature validation — **while GET keeps working**, because a GET has no body to hash. A distribution that demonstrably routes correctly and fails only on the one method the form uses, with an error about signatures, is a genuinely misleading place to start debugging.

The origin request policy must therefore be `AllViewerExceptHostHeader`. The exclusion is load-bearing rather than a limitation: SigV4 signs `Host`, and Lambda validates the signature against *its own* hostname, so forwarding the viewer's `Host: thangkhuat.dev` would break every request.

**Implementation note — two grants, not one.** AWS's OAC documentation lists two `add-permission` calls, for `lambda:InvokeFunctionUrl` *and* `lambda:InvokeFunction`. The second looked redundant and strictly broader, so it was omitted. A correctly signed request was then refused with `403 AccessDeniedException`. Reading that error is the useful skill: `AccessDenied` means the request **reached Lambda and was refused on authorization**, so routing and signing were both already working — verified separately by confirming the OAC was attached to the origin and the distribution reported `Deployed`. A signing or payload-hash fault returns `SignatureDoesNotMatch`; a routing fault never reaches Lambda at all. Both grants carry the same `source_arn` condition, so the broader action does not mean a broader caller.

**Trade-offs accepted:** Roughly five extra resources versus the public-URL design, and a browser-side hashing step that would otherwise be unnecessary. The failure modes are also less obvious — a misconfiguration surfaces as a signature error rather than a clear "forbidden."

---

### ADR-013 — Stay in the SES sandbox deliberately
**Status:** Accepted

**Context:** Every new SES account is sandboxed: it may only send to verified addresses, capped at 200 messages a day. The standard next step is to request production access.

**Alternatives considered:** Request production access, as almost every SES tutorial does at this point.

**Decision:** Stay in the sandbox. Verify the domain for sending and the single recipient address for delivery, and leave it there.

**Reasoning:** The restriction costs this feature nothing, because the function only ever sends to one address — the recipient is a constant in the configuration, not something a submitter influences. In exchange it is a hard containment control enforced by AWS **outside this account's own code**: even a completely compromised handler, with the IAM policy rewritten, could not use SES to mail an arbitrary third party. Requesting production access would delete that control to buy a capability the design does not want. The 200/day cap is also a free ceiling on the one leg of this feature that costs real money.

**Implementation note — the sandbox creates an IAM requirement.** Granting `ses:SendEmail` on the *sending domain* identity alone is not sufficient, and fails with:

```
AccessDenied ... not authorized to perform ses:SendEmail on resource
arn:aws:ses:<region>:<account>:identity/<recipient address>
```

The denied resource is the **recipient's** identity. SES authorizes `SendEmail` against every identity involved in the call, and the recipient is an identity here *precisely because of this decision* — the sandbox requires verified recipients, a verified recipient is an identity, and identities are authorization resources. The policy names both. Leaving the sandbox would remove this requirement along with the containment that motivates it.

**Trade-offs accepted:** One genuinely manual step that Terraform cannot automate — the recipient address is verified by clicking a link in that inbox, recorded in [`bootstrap.md`](bootstrap.md). Adding a second recipient later means verifying it too, and adding its identity ARN to the IAM policy. Both are the intended friction.

---

### ADR-014 — Per-behavior CloudFront forwarding
**Status:** Accepted (supersedes ADR-007)

**Context:** ADR-007 set `query_string = false` and `cookies.forward = "none"` and said explicitly that it would change when a dynamic backend arrived. It has.

**Decision:** Keep the default behavior exactly as ADR-007 left it. Add a single `ordered_cache_behavior` for the exact path `/api/contact` that forwards everything and caches nothing.

**Reasoning:** ADR-007's reasoning still holds for `/*` — nothing on the static half of the site varies by query string or cookie, and forwarding either would cost cache hit rate for no benefit. What changed is that one path now needs the opposite treatment, not that the original decision was wrong. Superseding it narrowly keeps the static site's cache behaviour intact and confines the exception to the path that requires it.

The exact path is used rather than `/api/*`, so a future path under `/api/` cannot be routed at this function by accident.

A test asserts the default behavior still forwards nothing, because that is a decision made before this feature and is exactly the kind of thing a later change loosens without noticing.

**Trade-offs accepted:** The distribution now mixes the legacy `forwarded_values` block on the default behavior with modern cache policies on the new one. AWS accepts this, but it is two idioms in one resource, and migrating the default behavior to cache policies is deferred work.

---

### ADR-015 — Honeypot and server-side validation, not CAPTCHA or WAF
**Status:** Accepted (concurrency ceiling attempted and not available — see below)

**Context:** The endpoint is public and unauthenticated. Every invocation costs a DynamoDB write and an SES send, so abuse is a cost problem before it is anything else.

**Alternatives considered:**
- AWS WAF with the managed rate-based rule — the "proper" answer, ~$5/month base plus per-rule charges
- A CAPTCHA (reCAPTCHA, hCaptcha) — effective, but adds a third-party script, a privacy question, and friction for every genuine visitor
- Per-IP rate limiting counted in DynamoDB with a TTL attribute

**Decision:** A hidden honeypot field, strict server-side validation with length caps, and a short function timeout. No CAPTCHA, no WAF.

**Reasoning:** WAF fails the same cost test ADR-009 applied to the ALB — a fixed monthly charge to protect a form that receives a handful of submissions. A CAPTCHA taxes every real visitor to stop bots that a honeypot stops for free. The honeypot is invisible to genuine users and costs nothing.

Validation is the part that actually matters, and it is authoritative on the server rather than in the browser: the HTML `maxlength` attributes are a usability affordance that anyone can bypass with `curl`. The handler's most important rule is rejecting CR and LF in the name and email fields, since both reach SES headers and a newline there is the classic email header injection vector — a submitter who lands a `Bcc:` line would turn the form into a relay sending DKIM-signed mail from this domain.

A filled honeypot returns a normal success response and writes nothing. Telling a bot it was caught is free tuning information for whoever runs it.

**Implementation note — the concurrency ceiling could not be set.** The design included `reserved_concurrent_executions = 2` as a hard cap on how fast a flood could run up a bill. AWS refuses it:

```
InvalidParameterValueException: Specified ReservedConcurrentExecutions for function
decreases account's UnreservedConcurrentExecution below its minimum value of [10]
```

New AWS accounts start at a concurrency limit of **10**, not the 1000 most documentation assumes, and 10 must remain unreserved. The two numbers being equal means no reservation of any size is possible. The ceiling still exists — the account limit bounds this function more tightly than the reservation would have — but it is not ours to set, and the expensive leg is capped separately by the SES sandbox's 200/day (ADR-013). Worth revisiting if the quota is ever raised.

**Trade-offs accepted:** A honeypot stops naive bots, not a determined attacker who reads the page source. Per-IP rate limiting was deferred rather than dismissed; the DynamoDB table it would need already exists. Accepted for a personal contact form where the realistic threat is spam volume, not a targeted adversary.

---

### ADR-016 — Every part gets a test before the next is built on it
**Status:** Accepted

**Context:** The contact form spans three layers — Terraform, a Python handler, and browser JavaScript — that only produce observable behaviour once combined. Before this, the project had no tests at all; `terraform validate` and a manual page load were the whole verification story.

**Alternatives considered:**
- Test the infrastructure only, and verify the handler and browser code by hand
- No automated tests, relying on `terraform plan` and manual checks as before

**Decision:** Each part ships with a test file that passes before anything is built on top of it. Terraform uses `terraform test`, the handler uses stdlib `unittest`, the browser module uses `node --test`. Any assertion guarding a security or cost control must additionally be shown capable of failing.

**Reasoning:** This is a sequencing rule more than a coverage target. A bug in an isolated handler costs minutes to find; the same bug once CloudFront, SES and DynamoDB are wired together costs an afternoon deciding which layer is lying. That is not hypothetical here — three separate faults surfaced only on a real apply, each of which now has a regression test.

The mutation requirement exists because the first Terraform suite reported eleven passing assertions before a single one had been shown capable of failing. Deliberately breaking each control is what turned it from decoration into coverage, and it has caught two mistakes since: an email-injection test that was passing for a different reason than its comment claimed, and a mutation so weak it proved nothing.

Error messages state *why* a control exists rather than what the comparison was, so a future failure explains itself rather than requiring archaeology.

Nothing needs installing. `node --test` is built into Node 18+, `unittest` is stdlib, and boto3 is stubbed rather than installed — it ships in the Lambda runtime, so a local copy would only be a second version to keep in sync.

**Trade-offs accepted:** `terraform test` requires AWS credentials, because mocking the `aws` provider wholesale makes every computed attribute unknown — including the ACM validation options an existing resource does `for_each` over, which fails the plan before any assertion runs. So the suite cannot run from a fork. Writing tests alongside each part is also slower than writing the parts, which is the point, but it is a real cost. The browser layer additionally required extracting the form script to `assets/contact-form.js` and teaching the deploy workflow to ship a second file.