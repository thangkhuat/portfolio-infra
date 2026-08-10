# Bootstrap — the manual steps Terraform doesn't own

Everything in this project is provisioned by Terraform except the steps below. Each one is manual
for a specific reason, recorded here so a rebuild from an empty AWS account is reproducible rather
than rediscovered by hitting errors.

Replace `<ACCOUNT_ID>` with the real AWS account ID. It's kept out of this file deliberately —
the repository is public, and the same reasoning keeps it out of the deploy workflow (see
[ADR-010](decision-log.md)).

---

## 1. IAM user for Terraform

Create an IAM user (this project uses `terraform-portfolio`), programmatic access only, with
`PowerUserAccess` attached. Configure it locally with `aws configure`.

Root credentials are never used for provisioning — see [ADR-005](decision-log.md) for the reasoning
and the trade-off accepted in choosing a policy this broad.

## 2. Inline policy: let Terraform manage the IAM resources

`PowerUserAccess` grants everything **except IAM**. Terraform therefore cannot create the OIDC
provider, the deploy role, or the contact form's Lambda execution role without an additional
grant, and `terraform apply` fails with `AccessDenied` on the CI/CD and contact-form sections of
`main.tf`.

Attach the following as an **inline policy** on the Terraform IAM user
(IAM → Users → `terraform-portfolio` → Add permissions → Create inline policy → JSON).
This project names it `terraform-manage-github-oidc`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageGitHubOidcProvider",
      "Effect": "Allow",
      "Action": [
        "iam:CreateOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:TagOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    {
      "Sid": "ManageProjectRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy"
      ],
      "Resource": [
        "arn:aws:iam::<ACCOUNT_ID>:role/github-actions-portfolio-deploy",
        "arn:aws:iam::<ACCOUNT_ID>:role/portfolio-contact-form"
      ]
    },
    {
      "Sid": "PassContactFormRoleToLambda",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/portfolio-contact-form",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "lambda.amazonaws.com"
        }
      }
    }
  ]
}
```

**Why this isn't managed by Terraform.** It grants the permissions Terraform itself runs with.
Managing it in Terraform would be circular — the permission would be needed before it could be
created, deadlocking a fresh account — and, more seriously, it would let Terraform rewrite the
limits of the identity it runs as. Anyone able to run Terraform, or holding its credentials or
write access to its state, could then grant themselves administrator. The thing that grants
privilege stays outside the thing being privileged.

**The `Delete*` and `List*` actions are not optional.** Terraform needs them to refresh state on
subsequent runs and to support `destroy`, not merely to create.

**Note on `iam:ListOpenIDConnectProviders`:** an earlier version of this policy included it scoped
to the provider ARN. That action only accepts `Resource: "*"`, so scoped to an ARN it can never
grant anything. It has been removed rather than widened — Terraform looks the provider up by ARN
with `GetOpenIDConnectProvider` and never needs the list call. A policy that advertises access it
cannot provide is worse than one without the entry.

**`iam:PassRole` is a separate statement on purpose, and it is the one to be careful with.**
Creating a Lambda function is not just a Lambda call — handing it an execution role makes AWS check
that the *caller* is allowed to give that role to a service. `PowerUserAccess` doesn't grant
`PassRole`, so without this statement `terraform apply` fails on `aws_lambda_function`, and the
error names Lambda rather than IAM, which sends you looking in the wrong place.

It is scoped to one role, and further conditioned on `iam:PassedToService`, because `PassRole` is a
classic privilege-escalation primitive: whoever can pass a role to a service they control
effectively inherits that role's permissions. Granted on `"Resource": "*"` — as plenty of guides
show — this single line would let anyone holding these credentials attach *any* role in the
account, including an administrator role, to a function they wrote. The narrow form grants the
ability to build this one function and nothing else.

Note that `PassRole` covers only `portfolio-contact-form`, not the deploy role. Nothing ever passes
`github-actions-portfolio-deploy` to a service — it's assumed via OIDC, which is a different
mechanism entirely — so including it would grant a capability that has no use.

## 3. Nameserver delegation at the registrar

The domain is registered with Porkbun; DNS is served from a Route 53 hosted zone. Terraform can
create the zone but cannot tell a third-party registrar to delegate to it.

After the first `terraform apply`:

```bash
terraform output name_servers
```

Enter those four nameservers in the Porkbun dashboard for the domain. Propagation is typically
minutes but can take longer; ACM certificate validation will not complete until it has finished,
and `terraform apply` will appear to hang on
`aws_acm_certificate_validation.portfolio_cert` until then.

See [ADR-003](decision-log.md) for why the domain is registered outside AWS.

## 4. GitHub Actions variables

After `terraform apply` completes:

```bash
terraform output github_actions_role_arn
terraform output cloudfront_distribution_id
```

Add all three under **Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
| --- | --- |
| `AWS_ROLE_ARN` | `github_actions_role_arn` output |
| `CLOUDFRONT_DISTRIBUTION_ID` | `cloudfront_distribution_id` output |
| `SITE_BUCKET` | the `bucket` argument of `aws_s3_bucket.portfolio_site` in `main.tf` |

The workflow checks all of these before assuming credentials and fails with a readable message if
any are unset, so a missing variable surfaces immediately rather than partway through a deploy.

**Variables, not secrets.** Neither is a credential. An ARN and a distribution ID are identifiers —
holding them grants nothing, because the role's trust policy is what gates access. Filing a
non-secret in the secrets store misrepresents what a secret is. See [ADR-010](decision-log.md).

**Refresh `CLOUDFRONT_DISTRIBUTION_ID` if the distribution is ever destroyed and recreated.** AWS
assigns a new ID, and the old one would still be accepted by the CLI — invalidating a distribution
that no longer serves the site, with the deploy reporting success. The workflow fails fast with a
readable message when the variable is unset, but it cannot detect a value that is merely stale.

## 5. Repository and owner IDs in the trust policy

The trust policy in `main.tf` pins the OIDC subject claim to GitHub's immutable identifiers:

```
repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main
```

A fork or a rename of this project needs those IDs replaced. They are not guessable — read them
from the API:

```bash
curl -s https://api.github.com/repos/<owner>/<repo> | grep '"id"'
curl -s https://api.github.com/users/<owner>      | grep '"id"'
```

If a deploy fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, the claim that
was actually presented is in CloudTrail — AWS deliberately omits it from the error, since naming
the failed condition would leak policy contents to an unauthenticated caller:

```bash
aws cloudtrail lookup-events --region ap-southeast-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity
```

The `userName` field is the exact subject claim. Diff it against the trust policy.

## 6. SES recipient verification

Terraform verifies the *sending domain* on its own: it publishes the `_amazonses` TXT record and
the three DKIM CNAMEs into the Route 53 zone it already manages, and
`aws_ses_domain_identity_verification` blocks until SES confirms. Nothing manual is involved, and
that is exactly why domain verification was chosen over verifying a single address
(see [ADR-013](decision-log.md)).

The *recipient* is different. The account stays in the SES sandbox deliberately, which means mail
is only delivered to verified addresses — so the notification recipient needs an identity of its
own. Terraform creates it and SES sends a confirmation mail, but the link has to be clicked by
hand. Terraform cannot read an inbox.

After the first `terraform apply`, open the inbox for the address in
`aws_ses_email_identity.notification_recipient` and click the link. Then confirm all three:

```bash
aws ses get-identity-verification-attributes --identities thangkhuat.dev --region ap-southeast-2
aws ses get-identity-dkim-attributes        --identities thangkhuat.dev --region ap-southeast-2
aws ses get-identity-verification-attributes --identities <recipient address> --region ap-southeast-2
```

All must read `Success`. Until the recipient does, **the form appears to work and no mail
arrives** — the endpoint returns 200 and the submission is stored, because a SES failure is
deliberately not treated as a failed submission. The evidence is in CloudWatch:

```bash
aws logs describe-log-streams --log-group-name /aws/lambda/portfolio-contact-form \
  --region ap-southeast-2 --order-by LastEventTime --descending --limit 1
```

A healthy submission logs `Accepted submission <uuid>`. A failed send logs
`Stored submission <uuid> but SES send failed` with the underlying error.

**Adding a second recipient later takes two steps, not one.** Verify the new address, *and* add its
identity ARN to the `SendNotification` statement in `main.tf`. SES authorizes `ses:SendEmail`
against every identity involved in a call, so an unlisted recipient fails with `AccessDenied`
naming that recipient's ARN — see [ADR-013](decision-log.md).

## 7. Destroying: deletion protection on the submissions table

`aws_dynamodb_table.contact_submissions` sets `deletion_protection_enabled = true`, because a
submission is a message from someone that no `apply` can regenerate. The consequence is that
**`terraform destroy` fails on that table** until the flag is turned off first:

```bash
# set deletion_protection_enabled = false in main.tf, then
terraform apply
terraform destroy
```

This is intended friction rather than an oversight — the extra step exists so that destroying real
correspondence is a deliberate act. Export the table first if the contents matter:

```bash
aws dynamodb scan --table-name portfolio-contact-submissions --region ap-southeast-2 > submissions.json
```

---

## Order of operations for a rebuild from zero

1. IAM user + `PowerUserAccess` (§1), configure locally
2. Inline IAM policy on that user (§2)
3. `terraform init && terraform apply` — will pause at certificate validation
4. Nameserver delegation at Porkbun (§3) — apply completes once DNS propagates
5. Click the SES verification link sent to the notification recipient (§6)
6. `AWS_ROLE_ARN` and `CLOUDFRONT_DISTRIBUTION_ID` repository variables (§4)
7. Confirm the repo and owner IDs in the trust policy match this repository (§5)
8. Trigger **Actions → Deploy to S3 → Run workflow** on `main` to verify the deploy path

Step 5 sits after DNS delegation because SES cannot verify the domain until the zone is
authoritative, and the recipient's confirmation mail is only sent once the identity exists.
