# Building a Personal Portfolio Site on AWS — Project Report

**Author:** Thang Khuat
**Live site:** [thangkhuat.dev](https://thangkhuat.dev)
**Repo:** [github.com/thangkhuat/portfolio-infra](https://github.com/thangkhuat/portfolio-infra)

## Overview

A custom-domain, HTTPS-secured personal site on AWS, provisioned entirely through Terraform with
zero manual console configuration — and, in a second stage, a serverless contact form built on
Lambda, SES and DynamoDB behind the same CloudFront distribution.

The project doubles as both the job-hunt asset itself and a concrete DevOps/cloud portfolio piece —
a CS graduate (Cybersecurity major, Distinction, RMIT) transitioning from five years as a
Registered Nurse in anaesthetics into cloud and infrastructure roles.

**Stack:** Terraform · AWS (S3, CloudFront, Route 53, ACM, Lambda, SES, DynamoDB, IAM) ·
GitHub Actions with OIDC · Git/GitHub

## Objective

The goal was never just a live website — plenty of free hosting would achieve that in minutes. It
was infrastructure that could be explained and defended line by line: real IAM access control, a
private storage layer with a single controlled entry point, a validated TLS certificate, and DNS
fully managed as code. GitHub Pages was considered and rejected early, since it would have removed
every piece of AWS infrastructure the project exists to demonstrate.

The contact form extended that standard to a dynamic backend without abandoning it. It was built
only after an earlier design was rejected on cost, and every security control it depends on is
asserted by an automated test.

---

# Part One — The static site

## Architecture

```
Visitor's browser
      │
      ▼
Route 53 (DNS) ──── resolves thangkhuat.dev to the CloudFront distribution
      │
      ▼
CloudFront (CDN) ─── HTTPS via ACM certificate, edge caching worldwide
      │  (Origin Access Control — signed requests only)
      ▼
S3 bucket ─────────── private, no public access, static files only
```

Every arrow is a Terraform resource, not a console click.

## Build process

1. **Access setup** — a dedicated `terraform-portfolio` IAM user (programmatic access only) rather
   than root credentials, to contain the blast radius of any future credential leak.
2. **Domain and DNS** — `thangkhuat.dev` registered via Porkbun (cheaper than Route 53
   registration), nameservers delegated to a Terraform-managed hosted zone.
3. **Storage** — an S3 bucket created fully private, all four public-access-block flags enabled. No
   public bucket, no static website hosting feature, by design.
4. **Certificate** — ACM certificate requested in `us-east-1` (a hard CloudFront platform
   requirement regardless of where other resources live), validated automatically through a
   Terraform-created DNS record rather than a manual email click.
5. **CDN and access control** — CloudFront fronts the bucket using Origin Access Control, so the
   bucket accepts signed requests from this one distribution and nothing else — not even a visitor
   who found the bucket's direct URL.
6. **Content** — a single-page portfolio replaced the initial test page.
7. **CI/CD** — GitHub Actions deploys on push, authenticating through OIDC rather than stored AWS
   keys.

## The OIDC migration

The deploy workflow originally used long-lived `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets.
Those never expire, weren't being rotated, and stay valid from anywhere until manually revoked.
Replacing them with OIDC role assumption removed the stored credential entirely rather than
shortening its life: GitHub mints a signed token per run asserting which repository and branch is
executing, and AWS trades it for credentials valid about an hour.

The first deploy failed, and the reason is worth knowing. GitHub issues subject claims carrying
**immutable numeric IDs**:

```
repo:thangkhuat@177017208/portfolio-infra@1322692264:ref:refs/heads/main   # actual
repo:thangkhuat/portfolio-infra:ref:refs/heads/main                       # what the guides show
```

`StringEquals` is exact, so the name-only form nearly every published guide shows silently never
matches. Matching the numeric form is strictly stronger anyway — names can be renamed, and a deleted
account's username can be re-registered by someone else, either of which would let a name-based
policy authorize an impostor.

AWS deliberately keeps the STS error vague, since naming the failed condition would leak policy
contents to an unauthenticated caller. CloudTrail records the claim that was actually presented,
which is how it was diagnosed rather than guessed.

---

# Part Two — The contact form

## Why it exists, after being rejected once

An earlier stage built a full VPC/ALB network layer, confirmed it working end to end, then destroyed
all 26 resources: an Application Load Balancer costs ~$16–22/month with no free tier at any account
age, and that fixed cost wasn't justified without real traffic. The same decision recorded that a
contact form was "genuinely unnecessary."

That judgement was about cost, and it still holds — but it was made when the only design on the
table was the ALB. Every component in the serverless version bills per use and costs nothing idle:
Lambda and DynamoDB on-demand both sit inside the always-free tier at this volume, and SES is $0.10
per thousand messages. **The same test applied to a different design gives the opposite answer**,
which is why the feature came back without contradicting the reasoning that had shelved it.

## Architecture

```
browser ──▶ CloudFront ──┬── /*            ──▶ S3 (private, OAC)
                         └── /api/contact  ──▶ Lambda URL (AWS_IAM, OAC)
                                                  ├──▶ DynamoDB   (submission stored first)
                                                  └──▶ SES        (notification, Reply-To submitter)
```

The form POSTs to a path on the site's own domain rather than to an AWS hostname. That is a
deliberate design choice with three consequences: no CORS is involved anywhere, the
`*.lambda-url.on.aws` hostname never appears in page source, and the function URL can be set to
`AWS_IAM` so that **only this CloudFront distribution can invoke it** — `curl` against it directly
returns 403.

It is the same containment shape already used for the S3 bucket, applied a second time.

## Security posture

The execution role is hand-written rather than using the managed `AWSLambdaBasicExecutionRole`,
which grants log writes against every log group in the account. Each statement is pinned to one ARN:

- `dynamodb:PutItem` only — no `GetItem`, `Query`, `Scan` or `DeleteItem`, so a compromised function
  can neither read back earlier submissions nor destroy them
- `ses:SendEmail` conditioned on `ses:FromAddress`, because verifying the domain authorized *every*
  address at it
- `logs:CreateLogStream` and `PutLogEvents` on one group — not `CreateLogGroup`, since the group is
  declared in Terraform

Assuming the handler is entirely under an attacker's control, it can write new items to one table,
send from exactly one address to exactly one pre-verified recipient, and write to one log group. It
cannot read or delete prior submissions, send as any other address on the domain, mail an arbitrary
third party, or reach any other resource. **Two independent controls enforce that** — the IAM
condition and the SES sandbox — and neither of them is the application code.

The handler's most important validation rule rejects carriage returns and line feeds in the name and
email fields. Both reach SES headers, and a newline inside a header value is the classic
**email header injection** vector: a submitter who lands a `Bcc:` line would turn the form into a
relay sending DKIM-signed mail from this domain.

## Staying in the SES sandbox on purpose

Every new SES account is sandboxed — it may only send to verified addresses, capped at 200 messages
a day — and the standard next step is to request production access. This project doesn't.

The restriction costs the feature nothing, because it only ever sends to one address. In exchange it
is a hard containment control enforced by AWS *outside this account's own code*: even a completely
compromised handler with a rewritten IAM policy could not mail an arbitrary third party. Requesting
production access would delete that control to buy a capability the design doesn't want.

## Testing

Three suites, no dependencies at any layer:

| Layer | Tool | Tests |
|-------|------|-------|
| Terraform | `terraform test` (plan-only, creates nothing) | 15 |
| Lambda handler | stdlib `unittest`, boto3 stubbed | 24 |
| Browser module | `node --test` | 13 |

The convention that matters more than the count: **any assertion guarding a security or cost control
must be shown capable of failing** before it's trusted — broken deliberately, confirmed to fail, then
reverted.

That rule exists because the first Terraform suite reported eleven passing assertions before a single
one had been proven able to fail. It has since caught two genuine mistakes: a test whose comment
claimed it verified a header-injection guard when the email format check was actually rejecting the
input independently, and a mutation so weak it proved nothing (re-serialising an object produces
byte-identical JSON).

---

## Challenges and lessons learned

**The bootstrap problem.** Terraform can't create its own first credentials, since it needs
credentials to make any API call. The first IAM user is created by hand; everything downstream is
managed. The same reasoning keeps the inline IAM policy that grants Terraform its own permissions
outside Terraform — managing it there would let Terraform rewrite the limits of the identity it runs
as, so anyone able to run it could grant themselves administrator.

**Region quirks aren't bugs.** CloudFront's certificate lookup only checking `us-east-1` looks like
an inconsistency until you read it as a documented platform constraint rather than something to fix.

**Caching isn't optional to understand.** An update can appear to go live without an invalidation
purely by chance — a cache miss at the serving edge. That's luck, not a deploy process.

**`iam:PassRole` is a privilege-escalation primitive.** Creating a Lambda function isn't purely a
Lambda call: handing it an execution role makes AWS check that the *caller* may give that role to a
service. Granted on `Resource: "*"`, as many guides show, it would let anyone holding those
credentials attach an administrator role to a function they wrote. It's scoped to one role ARN here,
and further conditioned on which service may receive it.

**Some errors are only readable if you know the taxonomy.** A `403 AccessDeniedException` from a
Lambda function URL means the request *reached* Lambda and was refused on authorization — so routing
and request signing were both already working. A signing or payload-hash fault returns
`SignatureDoesNotMatch` instead, and a routing fault never arrives at all. Knowing which of the three
you're holding narrows the search enormously.

**A correct design decision can hide a failure.** The handler returns HTTP 200 when only the email
leg fails, because the submission is safely stored and asking the visitor to resend would just
duplicate the record. That's still the right call — but it meant a completely broken mail path looked
like success from every external angle: 200 response, row in the table, no client-visible error. Only
the logs knew. The missing piece is an alarm on the error metric, and it's recorded as such.

**Three faults surfaced only on a real apply**, none of which code review would have caught:

| Fault | Cause |
|-------|-------|
| Reserved concurrency rejected | New AWS accounts start at a Lambda concurrency limit of **10**, not the 1000 most documentation assumes — and the required unreserved minimum is also 10, so no reservation of any size is possible |
| Signed POST returned 403 | AWS's OAC documentation lists **two** grants; `lambda:InvokeFunction` was judged redundant and omitted. It isn't |
| Notification email never arrived | SES authorizes `SendEmail` against **every identity in the call**, and the sandbox makes the recipient an identity too — so its ARN was required alongside the sending domain's |

Each now has a regression test. Collectively they're the strongest argument in the project for
testing infrastructure rather than only reading it.

**`for_each` isn't always available.** It must know its keys during graph construction, so it can't
iterate a value unknown until apply. "Prefer `for_each` over `count`" is real advice that stops
applying the moment the collection derives from a resource that doesn't exist yet.

## Outcome

A live, HTTPS-secured, custom-domain portfolio site with a working contact form, provisioned
entirely as code:

- Zero manual AWS console configuration for any resource, with every deliberate exception documented
  and justified in `bootstrap.md`
- A private storage layer and a private compute endpoint, each with exactly one controlled access
  path
- No long-lived AWS credentials anywhere — CI authenticates through OIDC
- 52 automated tests across three layers, with security assertions verified by mutation
- Sixteen architecture decision records covering not just what was chosen but what was rejected, and
  what turned out to be wrong

Steady-state cost is effectively zero: the only fixed charges are the domain registration and the
Route 53 hosted zone.

## Status

Live and stable. Known gaps are listed with reasoning under "Not yet built" in
`technical-requirements.md` — the most significant being alerting on a failed mail send. Full
reasoning for every decision, including the ones that were reversed, is in `decision-log.md`.
