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

## 2. Inline policy: let Terraform manage the OIDC resources

`PowerUserAccess` grants everything **except IAM**. Terraform therefore cannot create the OIDC
provider or the deploy role without an additional grant, and `terraform apply` fails with
`AccessDenied` on all three resources in the CI/CD section of `main.tf`.

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
      "Sid": "ManageDeployRole",
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
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/github-actions-portfolio-deploy"
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

## 4. GitHub Actions variable

After the OIDC resources exist:

```bash
terraform output github_actions_role_arn
```

Add it to the repository under **Settings → Secrets and variables → Actions → Variables** as
`AWS_ROLE_ARN`.

A **variable**, not a secret. An ARN is an identifier, not a credential — holding it grants nothing,
because the role's trust policy is what gates access. Filing a non-secret in the secrets store
misrepresents what a secret is. See [ADR-010](decision-log.md).

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

---

## Order of operations for a rebuild from zero

1. IAM user + `PowerUserAccess` (§1), configure locally
2. Inline OIDC policy on that user (§2)
3. `terraform init && terraform apply` — will pause at certificate validation
4. Nameserver delegation at Porkbun (§3) — apply completes once DNS propagates
5. `AWS_ROLE_ARN` repository variable (§4)
6. Confirm the repo and owner IDs in the trust policy match this repository (§5)
7. Trigger **Actions → Deploy to S3 → Run workflow** on `main` to verify the deploy path
