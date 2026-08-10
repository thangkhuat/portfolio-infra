# Functional Requirements — Personal Portfolio Site

What the site needs to *do*, from a visitor's or your own perspective — not how it's built underneath.

## Phase 1 — Static Site (complete)

| ID | Requirement | Status |
|----|-------------|--------|
| FR1 | Site is publicly accessible at `https://thangkhuat.dev` | ✅ Done |
| FR2 | All traffic served over HTTPS; no unencrypted access | ✅ Done |
| FR3 | Site loads quickly for visitors regardless of location | ✅ Done (CDN) |
| FR4 | Underlying file storage is not publicly accessible or discoverable | ✅ Done |
| FR5 | Site displays professional portfolio content (about, projects, contact) | ✅ Done |

**This phase is complete and live.**

## Phase 2 — Contact Form (complete)

| ID | Requirement | Status |
|----|-------------|--------|
| FR6 | A visitor can send a message from the site without needing an email client | ✅ Done |
| FR7 | Messages are delivered to the owner's inbox, and replying goes to the sender | ✅ Done |
| FR8 | Messages are stored durably, so a mail failure never loses a submission | ✅ Done |
| FR9 | The form resists automated abuse without taxing genuine visitors | ✅ Done |
| FR10 | The endpoint is not reachable except through the site's own domain | ✅ Done |
| FR11 | The site keeps working with JavaScript disabled — degraded, not broken | ✅ Done |

Notes on what "done" means for the less obvious ones:

- **FR7** — mail is sent from `noreply@thangkhuat.dev` with `Reply-To` set to the submitter, so a
  reply reaches the person rather than an unmonitored mailbox.
- **FR8** — the submission is written to DynamoDB *before* the email is attempted. If only the mail
  leg fails the visitor still gets a success response, because their message is safely stored and
  asking them to resend would only duplicate it.
- **FR9** — a hidden honeypot field plus server-side validation. No CAPTCHA, so a genuine visitor
  is never asked to prove anything (ADR-015).
- **FR11** — the `mailto:` link remains, and a `<noscript>` note points at it.

## Beyond this

No further requirements are actively planned. Known gaps, with reasoning, are listed under "Not yet
built" in `docs/technical-requirements.md` — the most significant being alerting on a failed mail
send, which is currently invisible to the visitor by design.