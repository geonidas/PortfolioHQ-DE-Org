# Portfolio HQ - notes for a coding session

Read `docs/handoff.md` before changing anything that touches the org, the sync paths or the
guest board. This file is the short version.

## Shape

- Salesforce DX project, one scratch org, alias `MyScratchOrg`. Jira is live: a status change on
  a `Work_Item__c` with an `External_Id__c` transitions a real Jira issue.
- Outbound: `WorkItemTrigger` (before update stages `Sync_Status__c = Pending`, after update
  enqueues) -> `WorkItemSyncQueueable` -> `WorkItemSyncService` -> `IWorkItemAdapter`.
- Inbound: `JiraWebhookResource` (guest, verifies HMAC, stores the row, parses nothing) ->
  `WebhookEventTrigger` publishes `Webhook_Event_Received__e` -> `WorkItemInboundProcessor`
  (Automated Process) -> the adapter's `parseInbound` -> upsert on `External_Id__c`.
- Boards: `WorkItemBoardController` + `lwc/workItemBoard` (internal, read and write);
  `PublicBoardController` + `lwc/publicWorkItemBoard` (guest, read only, DTOs, no ids). They
  share `lwc/boardLayout`, which imports no Apex. Keep it that way.
- Picklist API names live in `WorkItemStatus`, `SyncStatus`, `WorkItemType`, `ExternalSystem`,
  `DeliveryStatus`, `LogDirection`. Use them; do not write the literal.
- Vendor vocabulary belongs in the adapter. `WorkItemInboundProcessor` and everything above the
  adapter must not know what a Jira payload looks like. Asana is the next build and gets its own
  adapter, its own REST resource and its own signature scheme.

## Rules that fail silently when broken

- Never call `WorkItemSyncService` from a controller. The trigger already enqueues; a second call
  either throws (callout after DML) or double-pushes.
- Never write `Status__c` from a script or seed unless you mean to transition Jira.
- The guest must never gain class access to `WorkItemBoardController`; class access is per
  class, not per method. Guest-facing reads go through `PublicBoardController` and
  `PublicWorkItemSelector`, whose WHERE clause is the only enforcement of the parent project's
  `Is_Public__c`.
- `PublicBoardControllerTest` asserts the DTO key sets exactly. Adding a field to what an
  anonymous visitor receives is a deliberate act and the test is meant to fail.
- All callouts in a transaction happen before any DML. Logs buffer in memory.
- **No DML before `IWorkItemAdapter.parseInbound`.** An adapter is allowed to call out from
  there, and `AsanaAdapter` does - Asana's payloads name a resource and an action and carry
  neither title nor section, so the task must be fetched. Apex refuses a callout once the
  transaction holds uncommitted DML, so any earlier write breaks the call. It breaks it **for
  Asana only**, with `CalloutException: You have uncommitted work pending`, an error that never
  mentions Asana. Same family as the case-insensitive identifier trap: the message does not name
  the cause. `WorkItemInboundProcessor` therefore parses the whole batch first and does every
  write afterwards, including the log rows the adapters buffered.
- Inbound assigns title, type, parent and project only when the payload carries them.

## Workflow

- Deploy freely with `--source-dir`; retrieve only through `manifest/org-changes.xml`. A full
  retrieve churns formatting. After scoped deploys run
  `sf project reset tracking --target-org MyScratchOrg --no-prompt`.
- Deploying an LWC does not update the public site. Republish:
  `sf community publish --name "Test Professional Site" --target-org MyScratchOrg`.
- Deploying a permission set does not assign it. See the handoff for the assignments.
- Verify with `sf apex run test --test-level RunLocalTests` on the org and `npm run test:unit`,
  `npm run lint`, `npm run prettier:verify` locally. Report real numbers.
- `docs/tour/` is a code tour whose stops point at lines by snippet. After a change that moves or
  rewrites code a stop points at, run `npm run tour` (refreshes it) and `npm run tour:check`.
- Org-generated site scaffolding (`aura/`, `pages/`, `components/`, the `Communities*`, `Site*`
  and `Lightning*Controller` classes) is kept on purpose and excluded from lint and prettier.
  Do not edit or delete it.

## Conventions for a build

- At the end of every build step, write a ready-to-use commit message to
  `.commit-messages/build-NN-step-NN.txt` (imperative subject, wrapped body, grouped bullets, a
  `Verified:` line with real numbers, the Co-Authored-By trailer) and give the user the
  `git commit -F` command. Do not commit. Record failures and self-corrections, not just the
  outcome.
- Every step ships a diagram alongside the diff, unprompted, chosen for the decision the step
  made rather than the files it touched.
- At the end of every build, write `docs/build-summaries/build-NN.md` for the planning chat:
  decisions and their reasoning first, then open items carried into the next build. Decision
  registers go in `docs/adr/`.
- Update `docs/handoff.md` when org state, an invariant or a trap changes. It records what git
  cannot see.
