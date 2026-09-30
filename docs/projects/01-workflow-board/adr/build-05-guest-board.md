# Build 05 — Public Guest Board: Decision Register

Architecture decisions taken while exposing the work item board to unauthenticated site
visitors, read-only. Build 04 was designed for a guest user who did not yet exist; this
is where those bets were settled. Recorded so none of it gets re-litigated from memory.

|                |                                                               |
| -------------- | ------------------------------------------------------------- |
| **Build**      | 05 — public guest board                                       |
| **Branch**     | `feature/first-branch`                                        |
| **Commits**    | `9c6288d` (steps 2–3), `5035c89` (step 4), `d042602` (step 5) |
| **Decisions**  | 19                                                            |
| **Tests**      | 165 Apex, 43 Jest                                             |
| **Components** | 257 validated                                                 |
| **State**      | Live to anonymous visitors, verified in a clean browser       |

**Origin labels**

- **From spec** — written into Build 05's requirements.
- **Directed** — a decision the owner made when asked.
- **Proposed** — an implementation choice the spec left open.
- **Departs from spec** — a deliberate deviation, with reasoning recorded.

---

## The read-only guarantee

### ADR-001 — Read-only is a property of the code, not a permission

**Origin:** From spec

**Decision.** A separate `PublicBoardController` containing one method and no write path,
rather than reusing `WorkItemBoardController` behind a flag or a running-user check.

**Context.** Apex class access is granted per class, not per method. Any user who can
reach a class can invoke every `@AuraEnabled` method on it from the browser, whatever the
page renders. A guest who could reach `WorkItemBoardController` could call `changeStatus`
directly; hiding the detail panel prevents nothing.

**Consequences.** Read-only cannot drift. There is no write method to reach, so no
permission has to stay correct forever. Measured: the write controller has 2 public
methods and 1 write operation; the public one has 1 and 0.

### ADR-002 — Nothing the client sends can widen the result

**Origin:** From spec

**Decision.** `getPublicBoardData()` takes no parameters at all.

**Consequences.** There is no argument to omit, mis-default or tamper with. Visible on the
wire: the request carries `method=getPublicBoardData&...&asGuest=true` with no `params`.
The enforcement is the compiler — the test calls it with zero arguments, so adding a
parameter breaks compilation rather than silently widening scope.

### ADR-003 — A separate selector, not extra methods on the existing one

**Origin:** From spec

**Decision.** `PublicWorkItemSelector`, with its own narrower field list and a single
method whose `WHERE` clause is written into the query text.

**Context.** Build 04's selector takes a project scope and treats a blank one as "return
everything" — correct for an internal page, fail-open for a public one. Sharing a class
would mean sharing a field list, and a future widening edit would silently publish more.

**Consequences.** The two field lists cannot drift into each other, because they share no
line. `Description__c`, `Assignee__c` and `External_URL__c` appear in the guest path only
inside a comment explaining their absence.

### ADR-004 — DTOs cross the wire, never SObjects

**Origin:** From spec

**Decision.** Explicit `PublicBoardData` and `PublicCard` classes.

**Context.** An SObject carries every queried field to the browser. A DTO carries what was
chosen, so adding a field to the query does not publish it.

**Consequences.** The DTO's serialised key set is asserted as an **exact set** in the
tests, not as a blocklist. A blocklist only catches fields someone thought to forbid;
this fails on any addition, making publication of anything new a deliberate act.

### ADR-005 — No Salesforce ids are published

**Origin:** Departs from spec

**Decision.** The spec listed _parent id_; the DTO carries **`parentNumber`** — the
parent's auto number — and no Salesforce id anywhere.

**Context.** An id is an addressable handle; an auto number is not. Nesting works
identically, and the auto number doubles as the client's list key, so the component needs
no id either.

**Consequences.** Nothing an anonymous visitor receives can be used to attempt direct
record access. Asserted: no 18-character id appears in the live payload.

### ADR-006 — Errors return a fixed string

**Origin:** Proposed

**Decision.** Every failure returns `The board is unavailable right now.`

**Context.** A raw exception message can carry field names, object names and query text —
a partial map of the schema handed to an unauthenticated caller.

**Consequences.** Debugging a guest-side failure needs the server log, not the response.
Asserted in Jest: the error state renders neither `SELECT` nor a field name even when the
wire error contains both.

---

## The filter

### ADR-007 — Both public flags are required, and only one can be enforced by sharing

**Origin:** From spec

**Decision.** `WHERE Is_Public__c = TRUE AND Project__r.Is_Public__c = TRUE`, hardcoded.

**Context.** A criteria-based sharing rule can only reference fields on its own object, so
the `Work_Item__c` rule cannot require `Project__r.Is_Public__c`. A public work item under
a **private** project is therefore shared to the guest at record level and excluded only
by this query.

**Consequences.** The parent flag is enforced in exactly one place. That holds while
`PublicBoardController` is the only guest-reachable class touching these objects — any
future one inherits the obligation. Recorded in the sharing rule's own `description`,
which is the part that survives a retrieve.

### ADR-008 — `Short_Name__c` with no fallback to `Name`

**Origin:** Proposed

**Decision.** The guest card's project label is `Short_Name__c` only. Blank renders no
label.

**Context.** Build 04 falls back to `Project__c.Name`, which for a guest would publish the
internal project name to anyone with the URL.

**Consequences.** The seed script sets `Short_Name__c` so the field is populated in
practice. Asserted: the internal project name appears nowhere in the payload.

### ADR-009 — A withheld parent is not named, even indirectly

**Origin:** Directed

**Decision.** `parentNumber` resolves only when the parent is itself public. A child whose
parent is withheld simply has no parent, and no note explains its absence.

**Context.** Build 04 renders "Parent is not on this board" for an orphan. Telling an
anonymous visitor that a record they cannot see exists is a leak with no upside.

---

## Access

### ADR-010 — A separate guest permission set

**Origin:** From spec

**Decision.** `Portfolio_HQ_Guest`: read on two objects, eleven fields, one Apex class.
No create, edit, delete, View All, Modify All, tabs or standard objects.

**Consequences.** `Portfolio_HQ_Developer` grants tab visibility and object access a guest
must never hold, so the two sets never touch. `Is_Public__c` is among the granted fields
because `WITH USER_MODE` enforces FLS on filter fields too — without read on the flag, the
guest query throws rather than filtering.

### ADR-011 — No org-wide default changes

**Origin:** Directed

**Decision.** Neither OWD was touched.

**Context.** The spec expected `Work_Item__c` and `Project__c` to need tightening to
Private first, and expected that to cascade the way Build 03's ADR-017 did. Checking the
org first showed `ExternalSharingModel` was **already Private** on both — which is all
guest sharing rules require.

**Consequences.** Tightening the _internal_ OWD would have broken internal access: nine of
eleven work items are owned by Automated Process, and `Portfolio_HQ_Developer` holds
`viewAllRecords=false` on both objects, so a non-admin holder would have seen 2 of 11
records. The anticipated fix was both unnecessary and harmful.

### ADR-012 — Guest sharing rules key on `Is_Public__c`

**Origin:** From spec

**Decision.** `sharingGuestRules` on both objects, `accessLevel=Read`, criteria
`Is_Public__c = true`.

**Consequences.** Both sites in the org share one guest user, so the rule cannot be scoped
to one site — the webhook-endpoint guest gains the same read access. Acceptable: it is
read-only, on records already flagged public, and that guest has no class access to reach
them.

### ADR-013 — Two corrections found only by deploying

**Origin:** Corrected during the build

**Decision.** Guest sharing is `sharingGuestRules`, not `sharingCriteriaRules` — the
`guestUser` element exists only on the guest rule type. And `guestUser` takes the guest
user's **`CommunityNickname`**, not a site developer name.

**Consequences.** The value is `Test_Professional_Site` even though the board lives on
`/neoGeoTest`, which is site `Test_Professional_Site1`. It looks like a copy-paste error
and is correct. Recorded in both rules' `description` elements, because the XML comment
that first carried this warning was stripped by a retrieve (ADR-017).

### ADR-014 — Record ownership was the actual blocker

**Origin:** Discovered during the build

**Decision.** `JiraWebhookProcessor` sets `OwnerId` when it **creates** a record, and only
then. The seed script reassigns records synced before that change.

**Context.** Guest sharing rules do not share records owned by the Automated Process user,
and the webhook subscriber owns everything it creates. Measured: the guest could read 2 of
6 public records; reassigning one owner made it 3 of 6, instantly.

Two theories were ruled out first. `includeRecordsOwnedByAll` is **invalid** on
`SharingGuestRule` and the deploy rejects it. Recalculation lag was ruled out by five flat
polls and by flipping `Is_Public__c` off and on to force re-evaluation, which changed
nothing.

**Consequences.** Setting the owner on update too would reassign on every re-sync, so it is
creation-only. If no admin resolves, the owner is left alone — the record still syncs, it
is simply not guest-visible; failing a delivery over an ownership detail would be worse.
The profile-name lookup is brittle and says so in the code.

---

## The component

### ADR-015 — A separate guest component, not a mode on the existing one

**Origin:** Directed

**Decision.** `publicWorkItemBoard`, importing only `PublicBoardController`.

**Context.** `workItemBoard` statically imports `WorkItemBoardController`. An import is not
conditional, so a shared component would drag the forbidden class into the guest bundle
whichever branch ran. This is the same structural argument as ADR-001, one layer up.

**Consequences.** The guest bundle contains exactly one Apex import. I had recommended
extracting a shared view-model module and reversed that: the DTO is already flat and
differently shaped from the SObject, so a shared model would have to handle both, and it
meant refactoring a working component with 31 passing tests.

### ADR-016 — The public card is inert by design

**Origin:** Proposed

**Decision.** `publicWorkItemCard` is a separate component with no `role`, no `tabindex`,
no handlers and no events.

**Context.** `workItemCard` carries `role="button"`, a tabindex and key handlers for the
status-change path. Reusing it would put interactive affordances in front of a visitor
with no write access — worse than a plainly static card.

**Consequences.** Asserted in Jest: the board renders zero buttons, and the card exposes
no role or tabindex. No `lightning-*` base component appears anywhere in either guest
component, continuing Build 04's ADR-017 for the same reason — this one actually runs in
LWR.

---

## Things learned the hard way

### ADR-017 — Rationale belongs in `description`, not in an XML comment

**Origin:** Corrected during the build

**Decision.** Explanatory prose in metadata goes in a `description` element where the type
has one.

**Context.** A retrieve overwrote both sharing rules with the org's copy and stripped every
XML comment — including the one warning that the `guestUser` value looks wrong but is not.
`description` survived, because it is a metadata value rather than a comment.

**Consequences.** Field descriptions written since Build 01 are safe. XML comments in
metadata are documentation with an expiry date.

### ADR-018 — A Build 03 test that was right to fail

**Origin:** Corrected during the build

**Decision.** `GuestAccessTest` asserted the guest **cannot** read `Work_Item__c`. Build 05
deliberately made that false. The test was rewritten, not deleted.

**Consequences.** The runtime check now asserts `Integration_Log__c` and
`Integration_Secret__mdt` stay unreachable, and a new `guestReadsOnlyPublicWorkItems`
moves the guarantee to the level it now lives at. That assertion is one-directional on
purpose: sharing for records created inside a test is asynchronous, so asserting the
public record _is_ visible could flake, while asserting the private one is **not** visible
cannot falsely pass.

### ADR-019 — Seed data is deliberately partial

**Origin:** From spec

**Decision.** `scripts/apex/flag-public-demo-data.apex` flags one project and six of its
work items across the three configured statuses, leaving others private.

**Context.** No project was public, and an empty board is indistinguishable from a
permissions failure. Every rebuilt org starts with the same gap, so the script lives in the
repo.

**Consequences.** One of the withheld records is a **child of a public parent**, which is
what makes "no non-public record appears" checkable rather than assumed — it proves both
that the child is excluded and that its visible parent does not leak it.

---

## Open questions

### The integration owner is resolved by profile name — _before a second admin exists_

`integrationOwnerId()` queries for the oldest active `System Administrator`. Brittle
across orgs and languages. A dedicated integration user, named in configuration, is the
right answer.

### Ownership is a standing gap on every new org — _on the next rebuild_

Any org rebuilt from this repo syncs records owned by Automated Process until an admin
resolves, and the seed script is the only thing that repairs them.

### Unauthenticated callers can still create rows — _if the endpoint sees hostile traffic_

Build 03's endpoint drops the payload on a failed signature, so a rejected request costs
~106 characters rather than up to 131,072. The row **count** is still uncapped, because
capping it needs a query the guest cannot run under `with sharing`.

### `In Review` remains unreachable — _when Jira gains the transition_

Defined in the picklist, absent from the Jira board. Columns are configurable, so adding it
is a page edit.

### `Title__c` and `Parent_Work_Item__c` do not sync inbound — _when field sync is built_

Both are set by hand. A Jira-side change to either does not propagate, so the board can
show a stale title indefinitely.

---

## Proven versus assumed

| Claim                                                  | Status       | Evidence                                             |
| ------------------------------------------------------ | ------------ | ---------------------------------------------------- |
| Deploy and `RunLocalTests` pass                        | **Proven**   | 165 Apex, 257 components                             |
| `npm run test:unit` passes                             | **Proven**   | 43 Jest across 3 suites                              |
| A logged-out visitor sees the board                    | **Proven**   | Clean browser, six cards, three columns              |
| No non-public record in the payload                    | **Proven**   | Network response compared to the org; exact match    |
| No Salesforce id or excluded field published           | **Proven**   | Nine DTO keys; no 18-char id in the payload          |
| The guest reads exactly the public set                 | **Proven**   | `UserRecordAccess`: 6 of 11, matching `Is_Public__c` |
| `changeStatus` is unreachable as a guest               | **Proven**   | One class granted; asserted via `SetupEntityAccess`  |
| A guest cannot write                                   | **Proven**   | `System.runAs` + `USER_MODE` DML refused             |
| The internal board still works                         | **Proven**   | Untouched; its tests pass                            |
| A guest cannot reach `changeStatus` _from the browser_ | **Untested** | Inferred from class access, never attempted in-page  |
| Guest behaviour on a freshly rebuilt org               | **Untested** | Every assignment and record here was made by hand    |
