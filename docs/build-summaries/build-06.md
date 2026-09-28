# Build 06 — Field sync and the two-view board

**Status:** built, deployed, tested and **live to anonymous visitors.** Type and parent now sync
inbound from Jira, and the public board carries two views over one payload.

**Verified end to end:** 182 Apex tests, 55 Jest tests, both views rendering to a logged-out
browser, a live Jira edit populating type and parent, and zero network requests when the view
toggle is used.

Two commits on `feature/first-branch`: `e0fc34c` (step 2) and `8b13915` (steps 3–6).

---

## What build 06 delivered

**Parser**

- `IWorkItemAdapter.normalizeType`, implemented in `JiraAdapter` over a `TYPE_ALIASES` table
  beside `STATUS_ALIASES`.
- `JiraWebhookProcessor` reads `fields.issuetype.name` and `fields.parent`, and resolves parents
  in a second pass over the delivery batch.
- Two previously silent failures now write `Integration_Log__c` rows: an unresolvable parent, and
  a record created with no admin to own it.

**Guest read path**

- `PublicBoardController` resolves each row's nearest `Epic` ancestor in memory and returns both
  views from the one parameterless cacheable call.
- `PublicEpic` DTO: four fields, key set asserted exactly.
- `PublicWorkItemSelector` gains `LastModifiedDate` as an ordering key only.

**LWC**

- `publicEpicCard` — new, inert.
- `publicWorkItemBoard` — a view toggle, and both views laid out through one shared column builder.

**Data**

- `scripts/apex/flag-public-demo-data.apex` builds a hierarchy and plants the canary.

---

## Decisions made, and why

### 1. No stub records for unresolved parents

The spec contradicted itself — the prose said "do not create stub records", the test list required
them. Resolved in favour of no stubs.

A stub would be a titleless, projectless `Work_Item__c` appearing on the internal board as a blank
card, bought to save a link the child's next delivery makes anyway. Two of the three stub tests were
also near-tautologies: "the stub is not public" holds from field defaults alone, and "the parent's
own delivery fills the stub rather than duplicating it" is free from upserting on `External_Id__c`.

**The cost, accepted knowingly:** nothing back-fills the link when the parent later arrives. Only a
subsequent delivery for the _child_ repairs it. A third option — a `Parent_External_Id__c` field to
make resolution re-runnable — was offered and declined.

### 2. Assign only what the payload carries

`Type__c` and `Parent_Work_Item__c` follow build 04's rule for `Title__c`. Most deliveries are status
transitions carrying none of the three; writing a null through would blank known data on every one.

One refinement beyond the spec: an `issuetype` object present but with a blank `name` counts as
**absent**, not as unmapped. Overwriting a known type with `Unspecified` on the strength of malformed
input is worse than leaving it alone.

### 3. Two passes, because payload order must not decide correctness

A delivery batch can carry a child and its parent in either order. Resolving inline would miss a
parent not yet inserted — and would do it intermittently, which is the worst kind of bug to chase.
Pass one upserts everything, pass two links, with one query for parents the batch did not carry.

A payload naming an issue as its own parent is refused and logged. Nothing in the schema stops a
self-lookup pointing at its own row, and a cycle of length one is still a cycle for anything walking
ancestors.

### 4. The ancestor walk is bounded twice

Iterative, never recursive, over rows the single query already returned. A visited set catches a
cycle of any length; a depth cap of 10 catches a chain longer than any real hierarchy. Both degrade
to "orphan" rather than throwing — a malformed hierarchy must not take the public board down.

### 5. A withheld ancestor breaks the chain

The walk sees public rows only, so a task whose parent is private reads as an orphan even when a
public epic sits above that parent. This is build 05's rule applied upwards: a child whose parent is
withheld simply has no parent.

**Consequence, recorded rather than discovered later:** an epic's child count can legitimately
disagree with Jira. Counts cover public descendants only. Querying the true total would publish the
existence of records the visitor cannot see.

### 6. The filter could not live in the query, and that needed saying

The spec asked for the task-view filter to be "hardcoded in the query as before". It cannot be —
SOQL cannot express "nearest `Epic` ancestor is not Done" across arbitrary hops.

The query text keeps exactly the two public flags it had; epic and orphan filtering happens in
memory afterwards, where it can only ever **remove** rows from an already-gated set. The security
boundary is unchanged and still lives in one place.

### 7. `LastModifiedDate`, not `Remote_Last_Modified__c`

Ordering completed epics needed a timestamp. The semantically better field is not in
`Portfolio_HQ_Guest`, and the query runs `WITH USER_MODE` — reading it would throw until the guest's
readable field set was widened. A real cost for a field that is only ever an ordering key and appears
in no DTO. `LastModifiedDate` is standard and needs no grant.

### 8. The epic DTO carries no identifier at all

Four fields: title, status, totalChildren, completedChildren. No id, no auto number, no external key.
The list component keys rows on the array index, so no identifier is needed and therefore none is
published. An untitled epic is labelled in the component rather than being handed a record number the
payload deliberately omits.

### 9. One query, whatever the shape of the data

Ancestry and child counts are computed from rows already loaded. A per-epic query would put the guest
page one busy project away from the governor limit. Asserted in a test, and confirmed at 1 query
against the live org.

### 10. The epic view is the same board, not a second layout

Shipped first as In flight / Recently completed groups, then rebuilt as the same To Do / In Progress /
Done columns as the task view.

The trigger was forward context: the epic view is eventually meant to condense Jira work into epics
and **share the board with Asana tasks**. Two sources landing in one set of columns is only cheap if
the columns are already the shared thing. `toColumns(cards, decorate)` now serves both views — the
task view passes a decorator that nests children under parents, the epic view passes nothing.

What fell out of that rather than being built: epic columns follow the same `columns` property as the
tasks, an epic whose status no column accounts for lands in an **Other** region, and per-column counts
and empty states. Adding an Asana source later means adding cards to that input, not adding a view.

### 11. The toggle is a real button, and the cards are not

The inertness rule governs things that look actionable but aren't. A view control genuinely is
actionable, so it is a `<button>` with `aria-pressed`, focusable and keyboard operable without being
told to be. The cards stay inert.

Build 05's test asserting the board contained **zero** buttons was rewritten rather than deleted — the
same treatment build 05 gave `GuestAccessTest`. The guarantee was never "no buttons", it was "no
control that could act". It now asserts every button is a view toggle carrying `data-view`.

---

## Three mistakes worth recording

### The seed script nearly transitioned live Jira issues

The first draft assigned `Status__c` to two work items to make them epics. `WorkItemTriggerHandler`
enqueues a real outbound push on any status change to a record carrying an `External_Id__c` — so
running it would have transitioned real DOPP issues as a side effect of seeding demo data, breaking
the script's own documented promise that flagging data public never talks to Jira.

Caught by reading the trigger before running the script, not by running it. Rewritten to choose epics
from records that already hold the status each role needs, writing only `Type__c` and
`Parent_Work_Item__c`. Verified by `Integration_Log__c` holding flat at 14 rows across two runs.

### A test that passed without testing anything

The first "the toggle does not refetch" assertion compared `emit.mock.calls.length` to itself. The
adapter exposes no such counter, so both sides evaluated to `0` and the test passed vacuously.

Replaced with an assertion on the wire config: `getLastConfig()` returns `{}` before and after the
toggle, because the Apex method takes no parameters. A wire re-invokes only when its config changes,
so that is the fact that actually carries the claim — and adding a wire parameter now fails it.

### `standard__LightningSales` was never meant to be deleted

The spec said to "revert the stray metadata from earlier retrieves", which meant remove it from source
control. It was read as "delete from the org", which is impossible — the org rejects it as standard,
and separately because in-app guidance is attached — and took a whole atomic deploy down with it.

`.forceignore` is the correct fix, and it needed `sf project reset tracking` alongside: a pending
deletion lives in source tracking, not in file presence, so ignoring the path alone does not retract
it.

---

## What build 05's bets were worth

| Build 05 decision                                         | Verdict in build 06                                                                                                 |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Exact key-set assertion on the guest DTO                  | **Paid off.** Extended to the epic DTO for the same reason, and it is what makes a second payload a deliberate act. |
| Parameterless controller and selector                     | **Paid off.** A second view was added with no new method and nothing the client can send.                           |
| Cards inert, no base components                           | **Paid off.** `publicEpicCard` inherited the rule whole.                                                            |
| A withheld parent simply has no parent                    | **Paid off, and generalised.** The same rule now governs the ancestor walk upwards.                                 |
| `Type__c` and `Parent_Work_Item__c` set by hand           | **Superseded.** Both now sync from Jira.                                                                            |
| In flight / Recently completed grouping (build 06 step 4) | **Did not survive its own build.** Replaced by shared columns once the Asana direction was known.                   |

---

## Open items carried into build 07

1. **An unresolved parent reference is never back-filled.** The child must be delivered again after
   the parent exists. Closing it needs a `Parent_External_Id__c` field or the reconciliation job.
2. **The epic card does not truncate its title.** Real Jira summaries run to four lines in a column.
3. **Profiles re-conflict on every Apex deploy**, because the org auto-grants new classes to Admin.
   `sf project reset tracking` clears it each time; the minimal-retrieve manifest keeps it out of the
   way.
4. **A `npm audit fix` that bumps `sfdx-lwc-jest` to v8 breaks Jest completely.** Every suite dies on
   `@lwc/engine-dom`'s ESM export before a test runs.
