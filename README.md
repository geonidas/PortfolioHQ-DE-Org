# Portfolio HQ

Two-way sync between a Salesforce org and two work trackers, Jira and Asana, with a Kanban board
for the team and a read-only public board for anyone with the link. Built as ten numbered builds on
a scratch org; version 1 is complete.

**Start with [docs/handoff.md](docs/handoff.md).** It holds what the repo cannot tell you: org
state that is not in source control, the invariants that fail silently when broken, and the
traps that have each cost real time. `CLAUDE.md` is the short version for a coding session.

## What is here

| Area           | Where                                                                                                                                                            | What it does                                                                                                                                                                                                                                                                 |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Data model     | `objects/`, `customMetadata/`                                                                                                                                    | `Work_Item__c` keyed on a namespaced `External_Id__c`, `Project__c`, an integration log, a webhook delivery object and its platform event, a write-only secret staging object, protected secret metadata, per-source mappings and board rules, and the featured-epic setting |
| Outbound       | `WorkItemTrigger`, `WorkItemSyncQueueable`, `WorkItemSyncService`, `JiraAdapter`, `AsanaAdapter`                                                                 | A save stages the fields it changed - status, title, dates, priority - in a before-update trigger; a queueable pushes exactly those to Jira or Asana, 25 records a transaction, through a vendor-neutral `IWorkItemAdapter`, and records how far each push got               |
| Inbound        | `JiraWebhookResource`, `AsanaWebhookResource`, `WebhookEventTrigger`, `WorkItemInboundQueueable`, `WorkItemInboundProcessor`, `WorkItemInboundSweeper`           | Guest-reachable REST endpoints verify each vendor's HMAC over the raw bytes and store the delivery; a platform event moves it out of the guest's context, a queueable applies it through its source's adapter, and a scheduled sweeper retries what that did not finish      |
| Internal board | `WorkItemBoardController`, `lwc/workItemBoard`                                                                                                                   | Every work item the user can see, in Tasks and Epics views with a source filter and a sort; cards open in place to edit, move by drag or Move to, retry a failed push, and feature an epic on the public board; updates live through Change Data Capture                     |
| Public board   | `PublicBoardController`, `PublicWorkItemSelector`, `lwc/publicWorkItemBoard`                                                                                     | A separate controller, selector, permission set and DTOs, so that read-only is a property of the code; opens on the featured epic's work, or on its Epics view when none is featured, and re-reads every 30 seconds while a visitor is active                                |
| Shared         | `lwc/boardCard`, `boardEpicCard`, `boardToolbar`, `boardColumns`, `boardModel`, `boardLayout`, `boardTheme`; `EpicRollup`, `BoardSourceRules`, constants classes | One card, toolbar, layout and view model for both boards, none of which imports Apex; one set of epic rules and per-source answers in Apex; one home for every picklist API name                                                                                             |

Decisions and their reasoning are in `docs/adr/`, one register per build. Per-build narrative,
written for the planning chat, is in `docs/build-summaries/`.

**[The code tour](docs/tour/README.md)** walks through version 1 in seven short tours - the
concepts each part rests on, why it is built the way it is, and the patterns that recur - with
every stop on a real line of code. It runs in VS Code with the CodeTour extension, or reads as
Markdown on GitHub.

## Working on it

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

# Jest, lint, formatting and the code tour's line links, locally
npm run test:unit
npm run lint
npm run prettier:verify
npm run tour:check

# Pull back only the declarative metadata you changed in Setup
sf project retrieve start -x manifest/org-changes.xml --target-org MyScratchOrg
```

Some of the setup is org state rather than source: the Jira and Asana credentials, the webhook
registrations and their secrets, the scheduled sweeper and nightly purge, permission set
assignments, and which epic is featured. The handoff lists each one and how to restore it on a new
org.

The pre-commit hook runs Prettier on staged files, ESLint on staged component JavaScript, and Jest
on the tests related to staged components. Apex is formatted at Prettier's defaults; the org's own
site scaffolding under `aura/`, `pages/`, `components/` and the `Communities*`, `Site*` and
`Lightning*Controller` classes is excluded from both tools on purpose, as are profiles and
permission sets.

## Demo data

```bash
sf apex run --file scripts/apex/flag-public-demo-data.apex --target-org MyScratchOrg
```

Flags one project and a few of its work items public, shapes them into an epic hierarchy, and
plants a canary that must never render. It never changes an existing record's `Status__c`,
because a status change on a synced record pushes to the live source.
