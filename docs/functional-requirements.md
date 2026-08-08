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

**This is the finished, live project.** No further requirements are actively planned for it.

## Phase 2 onwards — future update

Dynamic backend (project data served from a database), CI/CD pipeline, and security hardening are all potential future work — not an active roadmap. Requirement details, if this is picked back up, live in `docs/decision-log.md` and `docs/technical-requirements.md`.