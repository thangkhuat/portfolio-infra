# Functional Requirements — Personal Portfolio Site

What the site needs to *do*, from a visitor's or your own perspective — not how it's built underneath.

## Phase 1 — Static Site (current)

| ID | Requirement | Status |
|----|-------------|--------|
| FR1 | Site is publicly accessible at `https://thangkhuat.dev` | ✅ Done |
| FR2 | All traffic served over HTTPS; no unencrypted access | ✅ Done |
| FR3 | Site loads quickly for visitors regardless of location | ✅ Done (CDN) |
| FR4 | Underlying file storage is not publicly accessible or discoverable | ✅ Done |
| FR5 | Site displays professional portfolio content (about, projects, contact) | ✅ Done |

## Phase 2 — Dynamic Backend (planned)

| ID | Requirement |
|----|-------------|
| FR6 | Visitors can submit a contact form |
| FR7 | Blog posts / project write-ups are stored and served dynamically |
| FR8 | (optional) Project/page view counter |

## Phase 3 — CI/CD (planned)

| ID | Requirement |
|----|-------------|
| FR9 | Pushing to `main` automatically redeploys the site |
| FR10 | Infrastructure changes are applied automatically via pipeline, not manual `terraform apply` |

## Phase 4 — Security Hardening (planned)

| ID | Requirement |
|----|-------------|
| FR11 | No credentials or secrets are hardcoded anywhere in the codebase |
| FR12 | Unusual AWS account activity triggers an alert |
| FR13 | All IAM permissions follow least privilege (no more standing `PowerUserAccess`) |
