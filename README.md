# Portfolio HQ

A two-way Jira integration on a Salesforce org, with a Kanban board for the team and a
read-only public board for anyone with the link. Built as a series of numbered builds on a
scratch org; the next build adds Asana as a second source.

**Start with [docs/handoff.md](docs/handoff.md).** It holds what the repo cannot tell you: org
state that is not in source control, the invariants that fail silently when broken, and the
traps that have each cost real time. `CLAUDE.md` is the short version for a coding session.

## What is here

| Area           | Where                                                                            | What it does                                                                                                                                                     |
| -------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Data model     | `objects/`                                                                       | `Work_Item__c` keyed on a namespaced `External_Id__c`, `Project__c`, an integration log, a webhook delivery object, a protected secret, and a platform event     |
| Outbound       | `WorkItemTrigger`, `WorkItemSyncQueueable`, `WorkItemSyncService`, `JiraAdapter` | A status change staged in a before-update trigger, pushed to Jira in chunks of 50 through a vendor-neutral `IWorkItemAdapter`                                    |
| Inbound        | `JiraWebhookResource`, `WebhookEventTrigger`, `WorkItemInboundProcessor`         | A guest-reachable REST endpoint verifies an HMAC over raw bytes and stores the delivery; a platform event hands it to a processor that runs as Automated Process |
| Internal board | `WorkItemBoardController`, `lwc/workItemBoard`                                   | Reads every work item the user can see, changes status                                                                                                           |
| Public board   | `PublicBoardController`, `lwc/publicWorkItemBoard`                               | A separate controller, selector, permission set and DTOs so that read-only is a property of the code                                                             |
| Shared         | `lwc/boardLayout`, `WorkItemStatus` and the other constants classes              | Pure layout helpers both boards import, and one home for every picklist API name                                                                                 |

Decisions and their reasoning are in `docs/adr/`, one register per build. Per-build narrative,
written for the planning chat, is in `docs/build-summaries/`.

## Working on it

```bash
# Deploy the code you changed. Deploy freely; retrieve minimally (see the handoff).
sf project deploy start --source-dir force-app/main/default/classes --source-dir force-app/main/default/lwc --target-org MyScratchOrg

# Apex tests, on the org
sf apex run test --target-org MyScratchOrg --test-level RunLocalTests --result-format human

# Jest, lint and formatting, locally
npm run test:unit
npm run lint
npm run prettier:verify

# Pull back only the declarative metadata you changed in Setup
sf project retrieve start -x manifest/org-changes.xml --target-org MyScratchOrg
```

The pre-commit hook runs Prettier and ESLint on staged files, and Jest on staged components.
Apex is formatted at Prettier's defaults; the org's own site scaffolding under `aura/`, `pages/`,
`components/` and the `Communities*`, `Site*` and `Lightning*Controller` classes is excluded from
both tools on purpose, as are profiles and permission sets.

## Demo data

```bash
sf apex run --file scripts/apex/flag-public-demo-data.apex --target-org MyScratchOrg
```

Flags one project and a few of its work items public, shapes them into an epic hierarchy, and
plants a canary that must never render. It never writes `Status__c`, because a status change
pushes to live Jira.
