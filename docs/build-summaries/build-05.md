# Build 05 — Public Guest Board (read-only site path)

**Status:** built, tested, validated and **live to anonymous visitors.** The component was
swapped, site public access was enabled and the site published after this summary was first
written; open items 1-3 below are closed as a result.

**Verified through a real anonymous browser session:** the board renders six cards across three
columns, and the `getPublicBoardData` network response was compared against the org - nine DTO
keys, no Salesforce ids, no excluded fields, and an exact match to the public record set.

Three commits on `feature/first-branch`: `9c6288d` (steps 2–3), `5035c89` (step 4), `d042602` (step 5).
**Verified at close:** 165 Apex tests, 43 Jest tests, deploy validate succeeded. Guest reads
exactly the six seeded public records, confirmed through `UserRecordAccess`.

> Step 1 left no commit — the route and view for `/work-item-board` were created in the org and
> retrieved in step 2–3, so that step was click-side setup rather than code.

---

## What build 05 delivered

Build 04 was designed for a guest user that did not exist. Build 05 is where that bet gets
settled — and it did not survive contact unchanged. The internal controller turned out to be
unusable for guests for a reason that has nothing to do with how it was written.

**New Apex**

- `PublicBoardController` — one cacheable method, no parameters, returns DTOs.
- `PublicWorkItemSelector` — one query, both public flags hardcoded into the query text.
- `PublicBoardControllerTest` — 15 methods.

**New LWC**

- `publicWorkItemBoard` — read-only board, wired only to `PublicBoardController`.
- `publicWorkItemCard` — inert: no role, no tabindex, no handlers.

**New metadata**

- `Portfolio_HQ_Guest` permission set.
- Guest sharing rules on `Work_Item__c` and `Project__c`, keyed on `Is_Public__c`.
- The `/work-item-board` route and view, tracked from the org.

**Changed**

- `JiraWebhookProcessor` now sets `OwnerId` on creation.
- `GuestAccessTest` rewritten.
- `scripts/apex/flag-public-demo-data.apex` added.

---

## Decisions made, and why

### 1. The read-only guarantee is structural, not conditional

This is the decision the whole build rests on, and it was forced by two platform facts rather
than chosen for elegance:

- **Apex class access is granted per class, not per method.** Any user who can reach a class can
  invoke every `@AuraEnabled` method on it from the browser, regardless of what the page renders.
  A guest who could reach `WorkItemBoardController` could call `changeStatus` directly.
- **An LWC import is not conditional.** A shared component with a "public mode" would still
  statically import `WorkItemBoardController`, dragging the forbidden class into the guest bundle
  whichever branch ran.

So the split is total: separate controller, separate selector, separate board component, separate
card component. Read-only is a property of the code — _there is no write method to reach_ — not a
permission that has to stay correct forever.

### 2. Nothing the client sends can widen the result

`getPublicBoardData` takes no arguments. `publicBoardItems()` takes no arguments and writes both
filters into the query text — not a parameter, not a page property, not a default. Build 04's
selector treats a blank project scope as "return everything", which is correct for an internal
page and **fail-open** for a public one. There is no code path here that produces an unfiltered
result.

### 3. DTOs cross the wire, never SObjects

An SObject carries every queried field to the browser; a DTO carries only what was chosen.
`Description__c`, `Assignee__c` and `External_URL__c` are absent from both the query _and_ the
DTO — two independent reasons they cannot leak.

The test asserts the DTO's serialised keys as an **exact set**, not a blocklist. Adding a field
now fails a test, which makes publishing something new to an anonymous visitor a deliberate act
rather than a side effect of editing a query.

### 4. No Salesforce ids are published

Parent linkage resolves to the parent's auto number, and **only when that parent is itself
public**. A withheld record is not revealed by implication — telling an anonymous visitor that a
record they cannot see exists is a small leak with no upside.

`projectLabel` is `Short_Name__c` with **no fallback to `Name`**, unlike the internal board. The
fallback would publish the internal project name to anyone with the URL.

### 5. Both public flags are required, and only one of them can be enforced by sharing

The query requires `Is_Public__c = TRUE` on the work item **and** on its project. This is not
belt-and-braces: **sharing rule criteria cannot reference `Project__r.Is_Public__c`**, so the
`WHERE` clause is the only place the parent flag is enforced anywhere in the system. That fact is
now recorded in the sharing rule's own description.

### 6. Errors return a fixed string

A raw exception message can carry field and query names. The controller throws
"The board is unavailable right now." and the component displays fixed wording, never the server
message.

### 7. No org-wide default changes

`ExternalSharingModel` was already Private on both objects, so the precondition was met without
touching anything. Tightening the **internal** OWD would have broken internal access — nine of
eleven work items are owned by Automated Process, and `Portfolio_HQ_Developer` holds
`viewAllRecords = false` on both objects.

### 8. Two corrections found only by deploying

- Guest sharing is `sharingGuestRules`, **not** `sharingCriteriaRules` — the `guestUser` element
  exists only on the guest rule type.
- `guestUser` takes the guest user's **CommunityNickname**, not a site developer name. The value
  is `Test_Professional_Site` even though the board sits on `/neoGeoTest`, which is site
  `Test_Professional_Site1` — both sites share one guest user. It looks like a mistake and invites
  being "fixed", so it is documented in both files.

### 9. The discovery that actually blocked the build: record ownership

Guest sharing rules **do not share records owned by the Automated Process user** — and the
webhook subscriber owns everything it creates. The guest could read 2 of 6 public records.
Reassigning one owner made it 3 of 6, instantly.

Two theories were ruled out before landing on it:

- `includeRecordsOwnedByAll` is invalid on `SharingGuestRule`; the deploy rejects it.
- Recalculation lag was ruled out by five flat polls and by flipping `Is_Public__c` off and on to
  force re-evaluation — no change.

**Fix:** `JiraWebhookProcessor` sets `OwnerId` when it _creates_ a record, and only then, so a
re-sync never reassigns an existing owner. If no admin can be resolved it leaves the owner alone:
the record still syncs, it is just not guest-visible. Failing a delivery over an ownership nicety
would be worse. The seed script reassigns records synced before the change.

Result: the guest reads exactly the six public records and nothing else.

### 10. Seed data is deliberately partial

`scripts/apex/flag-public-demo-data.apex` flags one project and six work items across the three
configured statuses. **Two are left private, one of them a child of a public parent**, so "no
non-public record appears" is checkable rather than assumed. A rebuilt org starts with nothing
flagged, and an empty board is indistinguishable from a permissions failure — which is why the
script lives in the repo rather than being run once and discarded.

### 11. A build 03 test that was right to fail

`GuestAccessTest` asserted the guest cannot read `Work_Item__c` — which build 05 deliberately made
false. It was **rewritten rather than deleted**: the runtime check now asserts
`Integration_Log__c` and `Integration_Secret__mdt` stay unreachable, and a new
`guestReadsOnlyPublicWorkItems` asserts a non-public record is absent.

That assertion is **one-directional on purpose.** Sharing for records created inside a test is
asynchronous, so asserting the public record _is_ visible could flake; asserting the private one
is _not_ visible cannot falsely pass.

### 12. Metadata comments do not survive a retrieve

A retrieve overwrote both sharing rules with the org's copy and stripped every XML comment,
including the note explaining the `guestUser` value. The `<description>` element survives, so the
rationale now lives there. Worth generalising: **any explanation that must survive belongs in a
description field, not an XML comment.**

### 13. The public card is inert by design

`workItemCard` carries `role="button"`, a tabindex and key handlers for the status change path.
Reusing it would put interactive affordances in front of a visitor with no write access — a card
that announces itself as a button but does nothing is worse than one that is plainly static.
Parent notes are dropped too: a note about a record a visitor cannot see is either noise or a leak.

---

## What build 04's bets were worth

| Build 04 decision                              | Verdict in build 05                                                                                                      |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `USER_MODE` on every query and DML             | **Paid off.** Carried straight into the public selector; a missing guest grant throws instead of quietly returning more. |
| No `lightning-*` base components               | **Paid off.** The public components run in LWR and inherited the rule for free.                                          |
| `Assignee__c` kept off the card                | **Paid off.** It is absent from the public query and DTO for the same reason.                                            |
| Columns from configuration                     | **Paid off.** Reused verbatim; the public component has the same `columns` property.                                     |
| Reuse `WorkItemBoardController` behind a guest | **Did not survive.** Per-class Apex access made a shared controller unsafe regardless of how it was written.             |
| Reuse `workItemCard`                           | **Did not survive.** Its interactive affordances belong to the write path.                                               |

The guest-readiness work was worth doing — four of six decisions carried. The two that failed
failed for reasons no amount of care inside the internal component would have changed.

---

## Open items carried into build 06

1. **The board is still not visible to a visitor.** The site page at `/work-item-board` hosts
   `c:workItemBoard`, which imports `WorkItemBoardController` and therefore cannot work for a
   guest. Swapping it for **Public Work Item Board** is the single remaining step, and it is
   click-side work in Experience Builder. **Resolved** - swapped and published; the org now
   serves `c:publicWorkItemBoard`.
2. **The network is `UnderConstruction` in source.** Carried over unresolved from build 03. An
   unactivated Experience network serves an under-construction page to public traffic rather than
   routing to the component — and it will look like a code fault when it happens. **Resolved** -
   it did look exactly like that: every path including the home page returned a 302 to login until
   site-level public access was enabled and the site published.
3. **Nothing has been verified through an actual anonymous browser session.** Guest access is
   proven via `UserRecordAccess` and `System.runAs`, which is strong evidence about _sharing_ and
   says nothing about _rendering_ in LWR. **Resolved** - verified in a clean browser with no
   session, including the network payload rather than only the rendered page.
4. **`integrationOwnerId()` resolves by profile name.** It queries for the oldest active
   `System Administrator`. Acknowledged in the code as brittle — a dedicated integration user,
   named in configuration, is the better long-term answer.
5. **Ownership is a standing gap on every new org.** Any org rebuilt from this repo will sync
   records owned by Automated Process until an admin exists to resolve, and the seed script is
   currently the only thing that repairs them.
6. **No ADR for build 05.** Builds 03 and 04 have decision registers; this build produced at least
   as much that would be re-litigated from memory — particularly the per-class access constraint
   and the ownership discovery.
7. **Unrelated metadata arrived with the retrieves.** `standard__LightningSales`, the
   `Unified_Cross_Platform_Workflow` flexipage and tab, and profile
   `applicationVisibilities`/`classAccesses` entries (all `enabled=false`) are now tracked. Noted
   in the commit as not from this build; worth a decision about whether they stay.
