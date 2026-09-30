# Portfolio HQ

Portfolio HQ is my personal, permanent Salesforce Developer Edition org. I use it myself and keep
building on it, so my Salesforce work stays continuous, visible and tested. It is a hub, not a
single app: a shared foundation - data model, security posture, deployment tooling and
documentation - that each project plugs into.

The organizing idea: I'm a one-person Salesforce agency and my own first client. My work is scoped,
tracked in Jira, decided in ADRs, and shipped through source control like a real engagement.

## Three roles the org plays

| Role                  | What it covers                                                                                                                   | Status                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| **Delivery platform** | Unified work tracking across Jira and Asana                                                                                      | **Built** - project 01                                                |
| **Public portfolio**  | An Experience Cloud site that hosts the public board, and will grow into a hub of projects, case studies and an Agentforce guide | **Built** - project 02; portfolio home page in progress; more to come |
| **Career CRM**        | Job search and relationship tracking on standard objects                                                                         | **An idea for later**                                                 |

## Projects

Each project has a numbered folder under [`docs/projects/`](docs/projects/) holding its overview,
decision records, build summaries, verification evidence and code tour. What the whole org shares -
the handoff and the org build guide - stays at the top of `docs/`.

| #   | Project                                                                   | Status                                 |
| --- | ------------------------------------------------------------------------- | -------------------------------------- |
| 01  | [Unified workflow board](docs/projects/01-workflow-board/README.md)       | Built: version 1, in ten builds        |
| 02  | [Experience Cloud site](docs/projects/02-experience-cloud-site/README.md) | Built; portfolio home page in progress |

### 01 · Unified workflow board - built

- Two-way sync between Salesforce and Jira, and between Salesforce and Asana: each source
  independently, never with each other.
- Webhooks are verified, staged, then processed asynchronously. Upserts are idempotent on the
  source's external id, and every callout and delivery is logged.
- A vendor-neutral schema, `Project__c` and `Work_Item__c`, with each vendor behind one adapter
  interface. Differences in status, type and priority are mapped per source, most of them in custom
  metadata.
- One set of Lightning Web Components, two audiences: an editable internal board and a read-only
  public board.
- [A code tour](docs/projects/01-workflow-board/tour/README.md) in seven parts walks through it,
  every stop on a real line of code.

### 02 · Experience Cloud site - built, portfolio page in progress

- An LWR site, source-controlled as a DigitalExperienceBundle, hosting the public board.
- Guest security: custom-object access only, reads through Apex that returns DTOs, a whitelist of
  what a visitor receives enforced by a key-set test, and verification while logged out.
- **In progress:** a portfolio home page that shows each project running. Staged on the scratch org
  with placeholder content; not yet on the Developer Edition org.

## What's next

Ideas for where the hub goes next, not commitments. Each becomes a numbered project with its own
plan when I start it.

- **The workflow board's next version**, starting from what version 1 left open.
- **More on the portfolio site**: a page for each project, case studies, and a way to get in touch.
- **A career CRM**: job search and relationship tracking on standard objects.
- **An Agentforce guide** on the site that answers questions about the projects.
- **Small, focused projects**, each pairing a Salesforce cloud or niche with a development
  fundamental. Some may live in their own repo or org and be linked from here.

## How I work

- Jira epics and stories with a written Definition of Done.
- GitHub for source control. Apex and Jest tests are the gates, alongside ESLint and Prettier; a
  pre-commit hook runs the local ones on every commit.
- ADRs for major decisions, in each project's `adr/` folder.
- AI-assisted development with Claude Code, with every build reviewed and tested by me.
- No click-only setup: configuration is retrievable and lives in the repo. The little that cannot -
  credentials, webhook registrations, scheduled jobs, permission set assignments - is written down
  in the handoff, with how to restore it on a new org.

## Repository layout

```text
force-app/                     All metadata: one package, shared by every project
scripts/                       Org build, seed data, the public-board audit, code-tour tooling
manifest/                      Deploy manifests, and the narrow one every retrieve goes through
build/targets/                 Per-org build targets (only *.example.json is committed)
docs/
  handoff.md                   Org state, invariants and traps: what git cannot see
  deploying-to-an-org.md       Building any org from one command
  projects/
    01-workflow-board/         Overview, ADRs, build summaries, verification, code tour
    02-experience-cloud-site/  Overview; its ADR and summary land here when the build closes
.tours/                        CodeTour files, one folder per project, generated from each tour
```

## Working on it

**Start with [docs/handoff.md](docs/handoff.md).** It holds what the repo cannot tell you: org
state that is not in source control, the invariants that fail silently when broken, and the traps
that have each cost real time. `CLAUDE.md` is the short version for a coding session.

```bash
# Deploy what you changed, by file or by bundle. Deploy freely; retrieve minimally (see the
# handoff). Anything the scheduled sweeper or purge depends on - the whole inbound path - can only
# deploy while they are unscheduled (handoff, section 3).
sf project deploy start --source-dir force-app/main/default/classes/PublicBoardController.cls --target-org MyScratchOrg

# LWC by manifest: --source-dir on the whole lwc folder fails on lwc/__tests__. Then republish the
# public site, which serves the bundle it was last published with
sf project deploy start -x manifest/build-08/package.xml --target-org MyScratchOrg
sf community publish --name "Test Professional Site" --target-org MyScratchOrg

# After scoped deploys, reset source tracking
sf project reset tracking --target-org MyScratchOrg --no-prompt

# Apex tests, on the org
sf apex run test --target-org MyScratchOrg --test-level RunLocalTests --result-format human

# Jest, lint, formatting and every project's code-tour line links, locally
npm run test:unit
npm run lint
npm run prettier:verify
npm run tour:check

# Pull back only the declarative metadata you changed in Setup
sf project retrieve start -x manifest/org-changes.xml --target-org MyScratchOrg
```

To build everything into another org - the Developer Edition org, or a fresh one with its own Jira,
Asana and webhooks - use `node scripts/build-org.mjs <target>`; see
[docs/deploying-to-an-org.md](docs/deploying-to-an-org.md).

Some of the setup is org state rather than source: the Jira and Asana credentials, the webhook
registrations and their secrets, the scheduled sweeper and nightly purge, permission set
assignments, and which epic is featured. The handoff lists each one and how to restore it on a new
org.

The pre-commit hook runs Prettier on staged files, ESLint on staged component JavaScript, and Jest
on the tests related to staged components. Apex is formatted at Prettier's defaults; the org's own
site scaffolding under `aura/`, `pages/`, `components/` and the `Communities*`, `Site*` and
`Lightning*Controller` classes is excluded from both tools on purpose, as are profiles and
permission sets.
