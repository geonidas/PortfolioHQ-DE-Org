# Build 04 — Work Item Board: Decision Register

Architecture decisions taken while building the first UI over the Work Item data — a
Kanban-style board with a configurable column set and an inline status change.
Recorded so none of it gets re-litigated from memory.

|                |                                                                  |
| -------------- | ---------------------------------------------------------------- |
| **Build**      | 04 — work item board                                             |
| **Branch**     | `feature/first-branch`                                           |
| **Commits**    | `8654899` (steps 1–5), `9484fdf` (step 6)                        |
| **Decisions**  | 26                                                               |
| **Tests**      | 149 Apex, 31 Jest                                                |
| **Components** | 241 validated at step 5, plus `Title__c` in step 6               |
| **Open items** | 7                                                                |
| **State**      | Deployed to the scratch org. Backfill run live, 11 of 11 titled. |

**Origin labels used below**

- **From spec** — written into Build 04's requirements.
- **Directed** — a decision the owner made when asked.
- **Proposed** — an implementation choice the spec left open.
- **Departs from spec** — a deliberate deviation, with reasoning recorded.
- **Corrected during the build** — a decision reversed or repaired after it was made.

> Build 04's spec is not in the repo, so unlike Build 03 these labels are reconstructed from the
> step commit records and the reasoning left in the code. Where provenance was not recorded the
> entry is labelled **Proposed**, which is the conservative reading. Step 6 is the exception: its
> commit states plainly that it was a correction to work already shipped.

---

## Columns

The single decision the rest of the build hangs off. Everything about which statuses exist,
which are shown, and which can be chosen resolves back to one configuration string.

### ADR-001 — Columns come from configuration, never from code

**Origin:** Proposed

**Decision.** The board reads an ordered, comma-separated `Status__c` list from a page property
(`columns`, defaulting to `To Do,In Progress,Done`). No column name appears in the markup or in
the rendering path.

**Context.** `Status__c` is a restricted picklist with five values, one of which — **In Review** —
has no Jira transition that reaches it. A hardcoded In Review column would have sat empty
indefinitely; omitting it in code would have meant a deployment on the day Jira gained the
transition.

**Consequences.** Adding a status is an edit to the Lightning page, not a release. Proven by
Jest rather than asserted: tests drive the component with arbitrary column names, with the
property absent, and with In Review supplied — the last one produces the column with no code
change.

### ADR-002 — The controller returns everything; the component buckets

**Origin:** Proposed

**Decision.** `getBoardData` returns every `Work_Item__c` the running user can see, unfiltered by
status. Bucketing into columns happens in `workItemBoard.rebuild()`.

**Context.** The alternative — one query per column, or a server-side grouping keyed by the
configured list — puts the column set into Apex, which is exactly what ADR-001 is avoiding. It
would also make the column count the query count.

**Consequences.** Column configuration stays a client concern, and ADR-010's fixed query count
falls out of it for free.

### ADR-003 — Nothing the controller returns is ever dropped

**Origin:** Proposed

**Decision.** A record whose status is not one of the configured columns still renders, in a
region below the board, marked unmapped.

**Context.** The same principle Build 03 applied inbound (ADR-022 there): an unmapped status is
surfaced, not hidden. A board that silently omits records is a board that lies about how much
work exists — and `Unspecified` is the _default_ value of `Status__c`, so the case is ordinary
rather than exotic.

**Consequences.** The count in the header and the sum of the columns can legitimately disagree,
which is why the unmapped region is visible rather than a tooltip.

### ADR-004 — The statuses a user may choose are the columns minus the current one

**Origin:** Proposed

**Decision.** `statusOptions` derives from the same configured list the columns come from,
filtered to exclude the status the card is already in.

**Consequences.** A status the board does not show is a status nobody can set. In Review is
therefore unreachable from the UI for exactly as long as it is unreachable from Jira, with no
second place to keep that rule in sync.

### ADR-005 — A child nests under its parent only when both sit in the same column

**Origin:** Proposed

**Decision.** Parent/child resolution happens before bucketing, so a card knows whether its
parent is on the board at all. Within a column, children nest. Across columns, the child renders
in its own column with a "Child of DOPP-nn" note instead.

**Context.** Nesting a child under a parent in a different column would put an In Progress card
under a To Do heading, which misreports both.

**Consequences.** Three cases all have to render: no parent, parent on the board, parent gone
(filtered out or deleted). An orphan gets "Parent is not on this board" rather than vanishing or
throwing.

---

## Read path

### ADR-006 — First selector classes in the repo, one per object

**Origin:** Proposed

**Decision.** `WorkItemSelector` and `ProjectSelector`, each owning a single field list and every
query for its object.

**Context.** Builds 01–03 query inline. Build 04 is the first build with a second consumer of the
same fields (`getBoardData` and `changeStatus` need identical shapes), so it is the first build
where a shared field list earns itself.

**Consequences.** Sets the convention for later builds. Adding `Title__c` in step 6 was a
one-line change in one place.

### ADR-007 — A blank project id means everything, not orphans

**Origin:** Proposed

**Decision.** When `projectId` is null, `forBoard` adds no `WHERE` clause at all. It does not
query for `Project__c = null`.

**Context.** The natural misreading of an empty filter field is "records with no project". On a
board placement the intent is "don't scope me". These differ by the entire dataset.

**Consequences.** Both the LWC setter and the Apex path normalise blank to null, and a test
(`aBlankProjectMeansEveryItemNotOrphans`) pins the interpretation so it cannot be refactored into
the other meaning.

### ADR-008 — A wrapper object, not a bare list

**Origin:** Proposed

**Decision.** `BoardData` carries `items`, `itemCount`, `projectId`, `projectLabel` and
`lastSyncedAt`.

**Context.** The board needs three things that are not properties of any single record: which
project it is showing, how fresh the data is, and whether "no cards" means an empty project or a
failed filter. A list can express none of them — an empty list and an error are the same value.

**Consequences.** The empty state and the error state are distinguishable in the component
without a second wire.

### ADR-009 — Freshness is computed in memory, not with an aggregate query

**Origin:** Proposed

**Decision.** `mostRecentSync` loops the records already loaded rather than issuing a
`MAX(Last_Synced__c)`.

**Context.** The rows are in hand, and a second query is a second thing that can fail — and a
second thing subject to the user-mode grant.

### ADR-010 — Query count pinned at 2, regardless of volume

**Origin:** Proposed

**Decision.** One query for work items, one for the project. Parent/child resolution, the project
label and the freshness stamp all come from data already fetched. Asserted at 200 records by
`bulkVolumeCostsAFixedNumberOfQueries`.

**Consequences.** The per-card query — the usual way a board like this dies — cannot be
introduced without failing a test that says so by name.

---

## Write path

### ADR-011 — The board writes `Status__c` and nothing else

**Origin:** Proposed

**Decision.** `changeStatus` performs a single-field update and stops. `WorkItemTrigger` stages
`Sync_Status__c` as Pending and enqueues the outbound push, exactly as it does for any other
edit.

**Context.** Calling `WorkItemSyncService` from the controller has two outcomes, both wrong: it
throws, because a callout cannot follow DML in the same transaction, or it pushes twice, because
Build 03's trigger has already queued one. The trigger is the only writer of the sync path and
the UI is just another caller.

**Consequences.** The board inherits Build 03's loop prevention untouched — it did not need a
suppression flag, a delta check or any awareness of Jira at all.

### ADR-012 — The queued job is counted, not assumed

**Origin:** Proposed

**Decision.** `Limits.getQueueableJobs()` is read before and after the DML, and the difference
becomes `pushQueued` on the response.

**Context.** "The trigger fired" is the load-bearing assumption of ADR-011. Counting makes it
evidence. `statusChangeWritesLocallyAndQueuesExactlyOnePush` asserts **exactly one** — which is
what would catch the controller ever pushing alongside the trigger.

**Consequences.** The component reports what actually happened rather than what should have.

### ADR-013 — The UI says Pending and never claims Jira agreed

**Origin:** Proposed

**Decision.** The response returns the post-save `Sync_Status__c`, which reads Pending, and the
component appends "This card stays Pending until Jira confirms."

**Context.** The push is asynchronous. Salesforce is saved when the call returns; Jira is not.
Any message implying otherwise is false for the length of the queueable, and permanently false if
the push fails.

**Consequences.** The sync flag on the card is shown whenever the status is anything but Synced,
with Failed styled distinctly from Pending. Asserted by
`statusChangeReportsPendingRatherThanClaimingJiraAgreed`.

### ADR-014 — `Unspecified` cannot be chosen

**Origin:** Proposed

**Decision.** `changeStatus` rejects `Unspecified` explicitly, before any query.

**Context.** `Unspecified` means "Jira reported a status we cannot map" (Build 03, ADR-022). It is
a landing value for inbound sync, not a destination a person can select — choosing it would ask
Jira to transition an issue to a status that does not exist there.

**Consequences.** It is also excluded implicitly by ADR-004, since it is not a configured column.
Both guards exist because the Apex method is callable independently of the component — and in
Build 05, from a context the component does not control.

### ADR-015 — Already-in-that-status is a no-op, not an error

**Origin:** Proposed

**Decision.** A change to the status the record already holds returns successfully with
`pushQueued = false` and "Already Done. Nothing was changed."

**Context.** The trigger's delta check would not push anyway, so an exception would report a
failure where nothing failed. Double-clicks and stale cards both land here.

**Also decided here.** Every other failure is converted to `AuraHandledException` with a readable
message — a raw exception reaches the client as an opaque server error, giving the component
nothing to render in its error state.

---

## Built for a guest user who does not exist yet

Build 05 puts this same controller behind an Experience Site guest. Three decisions were taken
now, at no cost, that would each be a retrofit later.

### ADR-016 — Every query and every DML runs in `USER_MODE`

**Origin:** Directed

**Decision.** Both selectors use `Database.queryWithBinds(..., AccessLevel.USER_MODE)` and
`changeStatus` uses `Database.update(..., AccessLevel.USER_MODE)`, in a build that ships only to
an internal Lightning page.

**Context.** A query written in system mode works identically today and silently returns fields a
guest must never see tomorrow. Enforcing user mode now means Build 05 fails loudly on a missing
grant rather than leaking.

**Consequences.** `queriesRunInUserModeSoAnUnprivilegedUserSeesNothing` runs `getBoardData` as a
Standard User and asserts refusal — the first test in this repo that proves an absence of access
rather than a presence of it.

### ADR-017 — No Lightning base components anywhere in the card

**Origin:** Proposed

**Decision.** `workItemCard` is plain HTML and CSS. Zero `lightning-*` components across both
bundles.

**Context.** Every base component is one more thing that can render or behave differently inside
an LWR site, and this card is destined for one. The cost of avoiding them at this level of
complexity is a stylesheet.

**Consequences.** Keyboard operability had to be built by hand — `role="button"`, `tabindex="0"`
and an Enter/Space handler — rather than inherited.

### ADR-018 — `Assignee__c` is deliberately absent from the card

**Origin:** Proposed

**Decision.** The selector's field list omits it, with the reason written into the class.

**Context.** Rendering a name means traversing to `User`, which a guest cannot read. Every
assignee in the org is currently null, so the field would show nothing today and break Build 05
later.

---

## Reachability

### ADR-019 — The Lightning page ships with a tab

**Origin:** Proposed

**Decision.** `Work_Item_Board.flexipage` is accompanied by a `CustomTab` and a `tabSettings`
grant on `Portfolio_HQ_Developer`.

**Context.** A FlexiPage with no tab exists in the org and cannot be opened. Shipping without one
would have left "now go create a tab in Setup" as undocumented click-only setup — the thing the
rest of this repo's metadata discipline exists to avoid.

### ADR-020 — The page leaves `projectId` blank on purpose

**Origin:** Proposed

**Decision.** The FlexiPage sets `columns` but leaves `projectId` empty, with a comment in the
metadata saying why.

**Context.** A project id in source is org-specific and would not survive a scratch-org rebuild —
it would resolve to nothing, and by ADR-007's rule an unresolvable scope is not the same as no
scope.

---

## The card — step 6

A design correction to work already shipped in step 5, which turned out to be a data-model gap
rather than a styling one.

### ADR-021 — The card had no name to show, so `Title__c` was added

**Origin:** Corrected during the build

**Decision.** Add `Work_Item__c.Title__c`, Text(255), holding Jira's `issue.fields.summary`. Add
it to `WorkItemSelector`'s field list and to `Portfolio_HQ_Developer`.

**Context.** The step 5 card led with `External_Key__c`, first and largest, so a column read as a
list of DOPP numbers rather than a list of work. The fix was not CSS: nothing in the model carried
a title. `Name` is an auto number, `External_Key__c` is a remote identifier, `Description__c` is
body text. Jira's summary was being parsed at the webhook and thrown away.

**Consequences.** The one thing a person would call the task now has somewhere to live. The
field's help text states it is synced and that local edits are overwritten on the next inbound
update.

### ADR-022 — An over-long summary is truncated, never rejected

**Origin:** Proposed

**Decision.** `JiraWebhookProcessor` truncates the summary to 255 against a `TITLE_MAX` constant,
matching how it already handles `Event_Type__c`, `External_Id__c` and error messages.

**Context.** A title too long for the field is a display problem. Failing the delivery over it
would drop a status change on the floor — trading a cosmetic fault for a correctness one.

### ADR-023 — A missing summary leaves the existing title alone

**Origin:** Proposed

**Decision.** `Title__c` is assigned only when the payload actually carried a summary.

**Context.** Writing the null through would blank a title we already hold, on every status-only
delivery. A delivery that omits the summary is not a retitling.

**Consequences.** `JiraWebhookPayloadFactory` gained an optional summary parameter where null
omits the field entirely, so the test can construct a delivery shaped like a real one rather than
one carrying an empty string.

### ADR-024 — With no title, the key stands in — but does not pose as one

**Origin:** Proposed

**Decision.** The heading falls back to the external key, rendered in a lighter weight and colour
(`heading heading-fallback`). The identity line then carries the auto number alone rather than
printing the key twice.

**Context.** Records that predate the field, and any issue Jira sends without a summary, have no
title. A fallback that looked identical to a real title would misreport the data as complete.

**Also decided here.** The title is clamped to two lines, so one long Jira summary cannot push a
column off screen and cards in a column stay comparable in height. The meta row is skipped
entirely when there are no points and no project — an empty flex row is invisible but still
spends the card's gap, which reads as a mis-padded card.

### ADR-025 — A backfill script, kept in the repo rather than thrown away

**Origin:** Proposed

**Decision.** `scripts/apex/backfill-work-item-titles.apex` reads `issue.fields.summary` over the
existing `Jira_Classic` named credential and fills `Title__c`.

**Context.** Records synced before the field existed sit on the key fallback until their next
inbound webhook — which for a finished issue may be never. Any org this deploys to has the same
gap, so the script is a migration, not a one-off.

**Consequences.** Three constraints shaped it: every callout happens before any DML, because Apex
refuses a callout once DML is pending and an anonymous block gets no second attempt; only records
with a null title are touched, so a rerun is cheap and a webhook-synced title is never
overwritten; and `SyncContext.suppressOutbound()` wraps the update, so a backfill can never write
back to Jira. A title-only update produces no `Status__c` delta and would not push anyway —
suppressing is the cheap way to be certain. Run live: 11 of 11 titled, 0 skipped, no status
changed, no outbound job queued.

---

## Testing

### ADR-026 — The wire-error test was wrong; the component was right

**Origin:** Corrected during the build

**Decision.** Fix the Jest assertion rather than the component, and add coverage for the
list-of-messages error shape.

**Context.** `createApexTestWireAdapter.error()` takes the error **body** as its first argument.
The test was passing a fully formed error object, nesting it one level too deep, and the
component's `readError` was being blamed for not unwrapping something no real wire would send.

**Consequences.** `readError` already handled the array-of-messages shape that Apex returns for
multiple errors, but nothing exercised it. Now something does.

---

## Open questions

Deliberately unresolved. None blocks the build; each has a known trigger point.

### The backfill script is untracked — _before the next commit_

`scripts/apex/backfill-work-item-titles.apex` is written, run and documented, but `9484fdf` did
not include it. ADR-025 says it is kept in the repo; git currently disagrees. One `git add`.

### No drag and drop — _first UI feedback_

Status changes go through a detail panel with buttons. Deliberate for now: keyboard-operable by
construction, no base components, and it behaves the same in an LWR site. It is the obvious next
ask, and HTML5 drag events in a guest-facing site are their own investigation.

### In Review is defined but unreachable — _when Jira gains the transition_

`Status__c` carries the value; no Jira transition reaches it. By ADR-001 and ADR-004 this is a
one-word page edit whenever that changes, with nothing to deploy.

### The board cannot be re-scoped from the UI — _when a second project exists_

Project filtering works in the controller and as a page property, but nothing in the component
lets a user switch projects. There is currently one project in the org, so the gap is invisible.

### Guest access is designed for but unproven — _Build 05_

ADR-016 to ADR-018 are all bets on a context that does not exist yet. The permission set, the
site placement and the guest's actual field visibility are Build 05's work; only then does
`USER_MODE` get tested by something other than a Standard User.

### Every save refetches the whole board — _at volume_

`refreshApex` after a status change re-runs `getBoardData` for all records, not the one that
moved. Correct and simple at current volume, and ADR-010 keeps it at two queries, but it is a
full round trip for a one-field change.

### `Title__c` is editable in the permission set — _cosmetic_

The field is granted `editable`, consistent with every other synced field on the object, and the
help text says edits are overwritten on the next inbound update. Nothing enforces that; the next
webhook carrying a summary simply wins.

---

## Proven versus assumed

What the suite and the deployment actually establish — and what they cannot.

| Claim                                              | Status       | Evidence                                                                  |
| -------------------------------------------------- | ------------ | ------------------------------------------------------------------------- |
| Deploy and `RunLocalTests` pass                    | **Proven**   | 149/149 Apex and 31/31 Jest at step 6; 241 components validated at step 5 |
| Adding a column needs no code change               | **Proven**   | Jest drives arbitrary names, the default, and In Review from config alone |
| A status change queues exactly one push            | **Proven**   | Queueable count read across the DML; asserted as exactly one              |
| The UI never claims Jira agreed                    | **Proven**   | Post-save `Sync_Status__c` asserted to read Pending                       |
| A blank project means everything, not orphans      | **Proven**   | Named test, both LWC and Apex paths                                       |
| Board volume costs a fixed number of queries       | **Proven**   | 2 queries at 200 records                                                  |
| An unprivileged user is refused                    | **Proven**   | `getBoardData` run as a Standard User under `runAs`                       |
| Unmapped statuses and orphan children still render | **Proven**   | Jest covers both, plus the untitled fallback                              |
| A summary-less delivery leaves the title alone     | **Proven**   | Apex test; absent summary, existing title unchanged                       |
| The backfill never writes back to Jira             | **Proven**   | Live run: 0 status changes, 0 outbound jobs queued                        |
| A real guest user can read the board               | **Untested** | No site placement yet; Build 05                                           |
| The board behaves the same in an LWR site          | **Untested** | Targets declared, base components avoided, never rendered there           |
| A live Jira status change reaches the card         | **Untested** | Inbound webhook was validated in Build 03, still not exercised end to end |
