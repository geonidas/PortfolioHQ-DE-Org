# 01 · Unified workflow board

**Status: built.** Version 1 is complete: ten numbered builds and a refactor pass, each deployed to
a scratch org and verified there, then built into the Developer Edition org with the one-command
org build ([docs/deploying-to-an-org.md](../../deploying-to-an-org.md)).

Two-way sync between a Salesforce org and two work trackers, Jira and Asana, with a Kanban board for
the team and a read-only public board for anyone with the link. It is the delivery platform in
[Portfolio HQ](../../../README.md), and its first project.

## What it does

- **Two-way sync** between Salesforce and Jira, and between Salesforce and Asana: each source
  independently, never with each other.
- **Webhooks are staged, then processed asynchronously.** Each vendor's endpoint verifies the
  signature over the raw bytes and stores the delivery; the work happens later, as another user.
  Upserts are idempotent on the source's own id, and every callout and delivery is logged.
- **A vendor-neutral schema.** `Project__c` and `Work_Item__c`, with each vendor behind one adapter
  interface. Differences in status, type and priority are mapped per source: in custom metadata for
  Asana and for both sources' priorities, while Jira's status and type aliases still live in its
  adapter (an open item in the handoff).
- **One set of components, two audiences.** An editable internal board and a read-only public board
  share one card, toolbar, layout and view model; read-only is a property of the public board's
  code, not a setting.

What version 1 leaves open is in the handoff's open items, and a version 2 will start from there.

## How it is built

| Area           | Where                                                                                                                                                            | What it does                                                                                                                                                                                                                                                                 |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Data model     | `objects/`, `customMetadata/`                                                                                                                                    | `Work_Item__c` keyed on a namespaced `External_Id__c`, `Project__c`, an integration log, a webhook delivery object and its platform event, a write-only secret staging object, protected secret metadata, per-source mappings and board rules, and the featured-epic setting |
| Outbound       | `WorkItemTrigger`, `WorkItemSyncQueueable`, `WorkItemSyncService`, `JiraAdapter`, `AsanaAdapter`                                                                 | A save stages the fields it changed - status, title, dates, priority - in a before-update trigger; a queueable pushes exactly those to Jira or Asana, 25 records a transaction, through a vendor-neutral `IWorkItemAdapter`, and records how far each push got               |
| Inbound        | `JiraWebhookResource`, `AsanaWebhookResource`, `WebhookEventTrigger`, `WorkItemInboundQueueable`, `WorkItemInboundProcessor`, `WorkItemInboundSweeper`           | Guest-reachable REST endpoints verify each vendor's HMAC over the raw bytes and store the delivery; a platform event moves it out of the guest's context, a queueable applies it through its source's adapter, and a scheduled sweeper retries what that did not finish      |
| Internal board | `WorkItemBoardController`, `lwc/workItemBoard`                                                                                                                   | Every work item the user can see, in Tasks and Epics views with a source filter and a sort; cards open in place to edit, move by drag or Move to, retry a failed push, and feature an epic on the public board; updates live through Change Data Capture                     |
| Public board   | `PublicBoardController`, `PublicWorkItemSelector`, `lwc/publicWorkItemBoard`                                                                                     | A separate controller, selector, permission set and DTOs, so that read-only is a property of the code; opens on the featured epic's work, or on its Epics view when none is featured, and re-reads every 30 seconds while a visitor is active                                |
| Shared         | `lwc/boardCard`, `boardEpicCard`, `boardToolbar`, `boardColumns`, `boardModel`, `boardLayout`, `boardTheme`; `EpicRollup`, `BoardSourceRules`, constants classes | One card, toolbar, layout and view model for both boards, none of which imports Apex; one set of epic rules and per-source answers in Apex; one home for every picklist API name                                                                                             |

**[The code tour](tour/README.md)** walks through version 1 in seven short tours - the concepts
each part rests on, why it is built the way it is, and the patterns that recur - with every stop on
a real line of code. It runs in VS Code with the CodeTour extension, or reads as Markdown on GitHub.

## In this folder

| Folder                                 | What it holds                                                                                          |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [`adr/`](adr/)                         | Decisions and their reasoning, one register per build from build 03                                    |
| [`build-summaries/`](build-summaries/) | Per-build narrative, written for the planning chat: decisions first, then what the next build inherits |
| `build-08/`, `build-09/`, `build-10/`  | Each build's verification: Lighthouse baselines, the owner's checks, before-and-after screenshots      |
| [`tour/`](tour/README.md)              | The code tour's source; `npm run tour` generates `.tours/01-workflow-board/` from it                   |

Org state, invariants and traps - what git cannot see - are in [the handoff](../../handoff.md),
sections 1-6, shared with the rest of the org.

## Build history

| Build       | What it added                                                                         | Records                                                                                                                                                         |
| ----------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 01          | The data model: `Project__c`, `Work_Item__c`, the developer permission set, test data |                                                                                                                                                                 |
| 02          | Outbound sync to Jira through a vendor-neutral adapter, logged, verified live         |                                                                                                                                                                 |
| 03          | The inbound Jira webhook: signed, staged, processed asynchronously                    | [ADR](adr/build-03-inbound-jira-webhook.md)                                                                                                                     |
| 04          | The internal work item board                                                          | [ADR](adr/build-04-work-item-board.md), [summary](build-summaries/build-04.md)                                                                                  |
| 05          | The public guest board on the Experience Cloud site                                   | [ADR](adr/build-05-guest-board.md), [summary](build-summaries/build-05.md)                                                                                      |
| 06          | Field sync, and the two-view board: Tasks and Epics                                   | [ADR](adr/build-06-field-sync-two-view-board.md), [summary](build-summaries/build-06.md)                                                                        |
| Refactor 01 | Inbound project linking, and the seams a second vendor lands on                       | [summary](build-summaries/refactor-01.md)                                                                                                                       |
| 07          | Asana as a second source system                                                       | [ADR](adr/build-07-asana-second-source.md), [summary](build-summaries/build-07.md)                                                                              |
| 08          | Board redesign, in-card editing, drag and drop, live updates                          | [ADR](adr/build-08-board-redesign.md), [summary](build-summaries/build-08.md), [design plan](build-08/design-plan.md), [verification](build-08/verification.md) |
| 09          | Priority, synced both ways, and sorting                                               | [ADR](adr/build-09-priority-and-sort.md), [summary](build-summaries/build-09.md), [verification](build-09/verification.md)                                      |
| 10          | A featured epic on the public board, set from the internal board; closes version 1    | [ADR](adr/build-10-featured-epic.md), [summary](build-summaries/build-10.md), [verification](build-10/verification.md)                                          |

## Demo data

```bash
sf apex run --file scripts/apex/flag-public-demo-data.apex --target-org MyScratchOrg
```

Flags one project and a few of its work items public, shapes them into an epic hierarchy, and
plants a canary that must never render. It never changes an existing record's `Status__c`, because
a status change on a synced record pushes to the live source.
