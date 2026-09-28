# Build 04 — Work Item Board (UI read/write layer)

**Status:** complete and deployed to the scratch org. Two commits on `feature/first-branch`:
`8654899` (steps 1–5) and `9484fdf` (step 6).
**Verified at close:** Jest 31/31, Apex 149/149 (`RunLocalTests`), backfill run 11/11.

---

## What build 04 delivered

The first UI in the project. Builds 01–03 produced the data model, the Jira adapter, the outbound
sync and the inbound webhook; build 04 put a Kanban board on top of it that a person can actually
read and act on.

**New Apex**

- `WorkItemBoardController` — `getBoardData(projectId)` (cacheable read) and `changeStatus(workItemId, newStatus)` (write).
- `WorkItemSelector` / `ProjectSelector` — first selector classes in the repo; one per object, single shared field list.

**New LWC**

- `workItemBoard` — columns, bucketing, parent/child nesting, selection, status change, empty/error states.
- `workItemCard` — presentational only, no base components.

**New metadata**

- `Work_Item_Board` FlexiPage + CustomTab, tab visibility on `Portfolio_HQ_Developer`.
- `Work_Item__c.Title__c` (Text 255).

---

## Decisions made, and why

### 1. Columns are configuration, not code

The board reads an ordered comma-separated status string from a page property; the default is
`To Do,In Progress,Done`. The controller returns every record the user can see and the component
buckets them.

_Why:_ adding a status becomes a page edit rather than a deployment. It also settled a live
question — `Status__c` has an **In Review** value, but the Jira board offers no transition to it,
so a hardcoded In Review column would have sat empty forever. Now it appears the day someone wants
it, without a release.

_Consequence:_ the statuses a user can pick in the detail panel are derived from the same
configured list, so a status the board doesn't show is a status nobody can set.

### 2. Nothing the controller returns is ever dropped

A record whose status isn't one of the configured columns still renders, in a region below the
board, flagged as unmapped. Same principle build 03 took with unmapped Jira statuses: surface,
don't hide.

### 3. The board writes `Status__c` and nothing else

`changeStatus` does a single field update and lets `WorkItemTrigger` stage `Sync_Status__c = Pending`
and enqueue the outbound push.

_Why:_ calling `WorkItemSyncService` directly would either throw (callout after DML) or push twice
(the trigger already queued one). A test pins this: exactly one queued job per status change.

_Consequence, deliberately visible in the UI:_ the response says Salesforce is saved and Jira is
running in the background, and the card stays `Pending` until the webhook confirms. The UI never
implies Jira has agreed.

### 4. Everything runs in `USER_MODE`, from day one

Every query in both selectors and the DML in `changeStatus` enforce user mode, even though build 04
is an internal-only page.

_Why:_ build 05 puts this same controller behind an Experience Site guest user. A system-mode query
written now would silently leak fields later; user mode means build 05 fails loudly on a missing
grant instead. A test runs `getBoardData` as a Standard User and asserts it's refused.

### 5. Built for the site before the site exists

- `workItemCard` uses **no `lightning-*` base components** — each one is a thing that can behave
  differently in an LWR site.
- `Assignee__c` is deliberately off the card: rendering a name means traversing to User, which a
  guest can't read (and every assignee is currently null anyway).
- The LWC already declares `lightningCommunity__Page` / `lightningCommunity__Default` targets.

### 6. `projectId` blank means _everything_, not _orphans_

The FlexiPage leaves `projectId` empty on purpose — a hardcoded id is org-specific and wouldn't
survive an org rebuild. The selector adds no `WHERE` clause at all when it's blank.

### 7. A Lightning page with no tab is unreachable

The FlexiPage ships with a CustomTab and a permission-set grant, rather than leaving "go create a
tab" as undocumented click-only setup.

### 8. Performance ceiling pinned by test

Query count is asserted at 2 across 200 records — no per-card query. Parent/child resolution and
"most recent sync" are computed in memory from rows already loaded.

### 9. Step 6: the card was leading with the wrong thing (design correction)

The card originally put `External_Key__c` first and largest, so a column read as a list of DOPP
numbers rather than a list of work — and nothing on the card said what the task actually _was_.

Root cause was in the **data model, not the CSS**: nothing carried a title. `Name` is an auto
number, `External_Key__c` is a remote identifier, `Description__c` is body text. Jira's
`issue.fields.summary` was being parsed and discarded at the webhook.

Fixes:

- **`Title__c` (Text 255)** added, wired into `WorkItemSelector` and the permission set.
- **Captured inbound**: the summary is truncated to 255 rather than rejecting the delivery (an
  over-long title is a display problem, not a reason to drop a status change), and is assigned
  **only when the payload carried one** — writing the null through would blank a known title on
  every status-only delivery.
- **Card layout**: title is the `h3` heading, clamped to two lines; the auto number and external
  key move to one muted identity line below it (`WI-0004 · DOPP-18`); with no title the key stands
  in as the heading but is toned down so an untitled card doesn't pose as a titled one; the meta
  row is skipped entirely when empty rather than rendered blank.
- **Backfill**: `scripts/apex/backfill-work-item-titles.apex` fills `Title__c` for records that
  predate the field — they'd otherwise sit on the key fallback until their next inbound webhook,
  which for a finished issue may be never. Callouts first, DML last (anonymous Apex gets no second
  chance), only untitled records, and `SyncContext.suppressOutbound()` so a backfill can never
  write back to Jira. Kept in the repo because any org this deploys to has the same gap.

### 10. One test bug found and corrected

A Jest wire-error assertion was passing a fully formed error object to
`createApexTestWireAdapter.error()`, which takes the error _body_ — nesting it a level too deep.
The component was right; the test was wrong. Coverage was added for the list-of-messages error
shape too.

---

## Open items carried into build 05

1. **`scripts/apex/backfill-work-item-titles.apex` is written but still untracked in git** — the
   step 6 commit message says it's kept in the repo, but the commit didn't include it. Needs to be
   added.
2. ~~No ADR for build 04.~~ Written: `docs/adr/build-04-work-item-board.md`, 26 decisions.
   Note that build 04's spec is not in the repo, so its origin labels are reconstructed from the
   step commits and code comments rather than recorded at the time.
3. **No drag and drop.** Status changes go through a detail panel with buttons. Deliberate for now
   (keyboard-operable, no base components, works in LWR) but it's the obvious next UI ask.
4. **In Review is defined but unreachable** from Jira. It's a one-word page edit whenever a Jira
   transition exists.
5. **The board is unscoped.** Project filtering exists in the controller and as a page property but
   nothing in the UI lets a user switch projects.
6. **Guest access is designed for but not proven.** `USER_MODE`, no base components and the LWR
   targets are all in place; build 05 is where the guest permission set and the site placement
   actually get exercised.
