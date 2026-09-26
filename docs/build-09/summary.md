# Build 09 — Priority and sorting

**Status:** complete and verified in the scratch org, against live Jira and Asana. The owner's
internal-board checks for the editor passed on 9/26; three checks remain for the owner, listed
under "Verified". Lighthouse is level with the baseline on every score.

Every work item now has a priority - High, Medium, Low, or none - that syncs with Jira and Asana
in both directions. Cards on both boards show it as a neutral badge on the date row; the internal
board's open card edits it; both boards sort by due date or by priority. The backfill filled every
existing item from its source.

Meeting the live org changed more than the plan did. The build prompt carried two wrong ids, which
the live reads corrected at step 0. Jira's own edit metadata said priority could not be written on
four issue types, and a real write proved it could. The first outbound check found a race older
than priority - a late echo showing an earlier value as Synced - and the owner chose to fix it in
this build, so step 5 made every push stamp the source's own time for what it wrote. And a Jira
timeout during the owner's checks exercised Failed, the pending hold and Retry for real. All of it
is below, with the build's own mistakes.

**Verified:** 461 Apex tests, 100% pass (409 at the end of build 08); 271 Jest (232); eslint and
prettier clean; zero axe violations in the public board across nine states, both sorts at both
sizes, colour contrast included; a sort change sends no request; the public board answers an
anonymous visitor with HTTP 200 and one SOQL query; Lighthouse 97 / 100 / 96 / 82 desktop and
71 / 100 / 96 / 82 mobile, level with the baseline.

Nine commits on `feature/first-branch`, one per step. No separate branch: the owner merges
`feature/first-branch` to `main` after this build.

---

## What build 09 delivered

**The field and its mapping (step 1)**

- `Work_Item__c.Priority__c`: a restricted picklist, High, Medium, Low in that order, no default,
  not required. Internal read and edit from step 1; guest read from step 5.
- Eight `Field_Mapping__mdt` rows keyed on ids: Jira `2`, `3`, `4` and the en dash `10000`, which
  maps to blank; the Asana Priority field's gid and its three option gids.
- `Maps_To_Blank__c`, a new checkbox on the mapping type, and `FieldMappingService.isMapped`: the
  table can now say "this id means none", distinct from "this id means nothing we know".
- `Board_Source__mdt.Supports_Priority__c`, true for both sources, read by the editor.

**Both directions (steps 2 and 3)**

- Inbound: Jira's `fields.priority.id`; Asana's Priority field found by its gid, never its name,
  with an empty field as none. A priority carried as none clears; an absent one leaves the field
  alone; an unknown one leaves it alone and logs the id; a pending one is held back.
- Outbound: `PRIORITY` joined `SyncField`, so `Pending_Push_Fields__c`, per-save ownership and Retry
  carry it with no new mechanism. Jira gets `priority: { id }` on the same PUT as title and dates,
  blank as the en dash; Asana gets `custom_fields` on the same task update, blank as `null`.
- `saveDetails` takes a priority, where null means "not sent" and blank means none.

**The backfill (step 4)** - the existing script, extended, now writing only what differs. Every
item took its source's priority: Jira 14 Medium; Asana High 3, Medium 1, Low 1, none 1. A second
run changed nothing.

**The payloads, and the late echo (step 5)**

- Both card payloads carry `priority` and `priorityRank`; the rank comes from the picklist's own
  order, in `WorkItemPriority`, so no priority name appears in Apex logic or any component. The
  public query gained the field and stayed one query.
- A push stamps `Remote_Last_Modified__c` with the source's own time for what it wrote: Jira by one
  more read, Asana at no cost. The late echo of an earlier push is now retired as stale.

**The boards (steps 6 and 7)**

- A neutral badge on the date row, heard as "Priority: High", absent for none. It drops below the
  dates when there is no room beside them rather than making them wrap - measured live at three
  widths. The public open card shows it read-only.
- A Priority select in the internal open card, between the dates and Save, only for a source that
  holds one, with the choices sent by the board.
- A Sort control after View and Source on both boards: Due date (the default) or Priority, sorted
  in the browser. It survives polls, live refreshes and filter changes, and a moved card lands in
  its sorted place.

**Gates that did not exist before**

- The audit fails if a sort change reaches Apex, and checks nine states rather than seven.
- A test replays the WI-0003 race and proves the late echo is ignored.
- A test reads the deployed mapping rows and fails if any priority does not round-trip for either
  source.
- `check-priority-sources.apex` re-reads both tools' priorities; `listen-work-item-changes.mjs`
  prints Change Data Capture events from the command line.

---

## Decisions, and why

The nine decisions the owner made before the build are in `docs/adr/build-09-priority-and-sort.md`
with their reasoning. In short: blank is none, with no sentinel; map by id, never by name; a
restricted three-value picklist; an unknown inbound value is logged and ignored; sorting is
client-side; Due date is the default and both sorts end on the key; epics keep their order; the
sort is not remembered; the badge is neutral text.

Five more were made during the build, each recorded in the ADR:

### 1. "None" is a checkbox on the mapping row, not an empty value

`Normalized_Value__c` was required, and an empty one already meant "half-filled, map nothing" -
with a test holding it to that. So a row maps to blank only when `Maps_To_Blank__c` says so. The
guard against half-filled rows survives, and Jira's en dash has a row that means none.

### 2. `saveDetails` reads null as "not sent"

The board before build 09 calls with four arguments, and so does any board left open in a tab
across an update. Read as none, the missing fifth argument would have cleared the priority of every
record such a card saved and pushed the en dash to Jira, silently. Blank is the explicit none. The
owner's live check proved blank survives the trip from the browser.

### 3. The guest's read grant moved to the payload step

Step 1 listed it, but the grant fails the test that pins the guest's readable fields, which step 5
was told to update. Granting and publishing a field to anonymous visitors stayed one change, and
both guest tests failed first on it, as build 08's did.

### 4. A push stamps the source's own time (the owner chose to fix it here)

Found live in step 3: a push left `Remote_Last_Modified__c` alone, so an echo of an earlier push,
processed late, counted as newer and showed the earlier value as Synced until the later echo put it
right. Every pushed field was exposed. The adapter now reports the source's own timestamp of what it
wrote, and the write-back stores it, forward only. Jira needs a read for it - its edit and
transition answer 204, and `returnIssue` returns no `updated` (probed live) - so a push costs up to
four callouts and chunks are 25. Rejected: Salesforce's own clock, which would put two vendors'
clocks into one comparison. The windows it leaves, and the fix that would remove the class - fetch
Jira's current state on every delivery, as Asana already does - are a version 2 item by the owner's
decision.

### 5. Three readings of the sort decisions

"Key" is the record number, compared as a number. In the Epics view the items that sort are the
cards passing through, because an epic card lists no items. After a drop, focus stays where it was,
as build 08 chose; after Move to it follows the card into its sorted place.

---

## What meeting the live org changed

- **Two ids in the prompt were wrong (step 0).** Jira's Low is id `4`, not `2` - the prompt gave
  `2` to both High and Low. And `1218524467731227` is the Asana workspace; the synced project is
  `1218523643929429`. The live reads won, and the ADR records both.
- **Jira's edit metadata was wrong about Jira (step 0).** It lists priority on Story alone, and the
  first report said Jira would refuse it on four issue types. The owner asked whether fields could
  be left out when they do not apply; answering that needed a real test, and a real change landed on
  a Task, an Epic, a Subtask and a Bug. DOPP is team-managed, and its `editmeta` describes layout,
  not what the API takes. No Jira setup was needed.
- **The late echo (step 3).** Deliveries were taking 30 to 50 seconds that day, and two saves on
  WI-0003 fell inside one echo's delay. Fixed in step 5, and proven live by re-delivering a stale
  echo after a newer push: Ignored.
- **A real timeout (step 6).** During the owner's checks, one Jira edit took over ten seconds to
  answer; the push failed though Jira had applied it. The card went Failed with the reason, Jira's
  echo was held back because the priority was still pending, and Retry sent it again and settled
  Synced - the whole failure path, unplanned and correct.
- **The date row (step 6).** Measured live at 1440, 1024 and 375: a Medium badge beside three dates
  at 1024, or two dates at 375, does not fit. It drops below instead of wrapping the dates.
- **Priorities the owner had set in Asana.** Three High, one Medium, one Low - the backfill brought
  in exactly those, cross-checked by reading each task directly.

---

## Mistakes worth recording

- **A step 0 finding that was wrong, reported as a blocker.** The editmeta claim above asked the
  owner for a Jira settings change. A write was the only real test; `editmeta` is not, in a
  team-managed project, and a write of the value already held proved nothing either - Jira answered
  204 without looking. Recorded in the handoff so it is not repeated.
- **A branch nobody asked for.** Step 0 cut `feature/build-09`, as the prompt named it; the owner's
  next `git push` failed for want of an upstream. Moved back to `feature/first-branch`, and a note
  now says to ask first.
- **The same traps as ever, hit anyway.** A test filtering on a long text area failed to compile
  (step 2). The first LWC deploy stopped on source-tracking conflicts because tracking was reset
  after the attempt instead of before (step 7). Both are in the handoff; both happened.
- **Three shell and tooling slips.** The Change Data Capture check first failed on a stale token
  from `sf org display` (step 1). A live-check loop under zsh sent ids like `"2 High"`, which Jira
  refused; nothing changed (step 2). A badge was measured at 45px from an unstyled probe - LWC
  scopes a component's CSS, so a bare span gets none - when the real one is 60 (step 6).
- **Comparisons at the wrong precision.** The backfill's "has this changed" compared a payload's
  milliseconds with a stored Datetime, which Salesforce keeps to the second, and reported 20 changes
  on a run that changed nothing (step 4). Fixed before the second run; the handoff now says so.
- **Tests weaker or narrower than they looked.** A "children sort within their parent" test would
  have passed with no nesting at all until it read the parent's list (step 7). Three assertions went
  unupdated for step 5's extra callout until a validation-only deploy caught them. Found by the
  build's own checks, before landing.

---

## Open items carried forward

| Item                                                                                                                                                                                                                                                               | Trigger point                           |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------- |
| A new priority value added in Jira or Asana is logged and ignored: the field keeps what it holds and the log names the id. Supporting one is a future build - a picklist value and a mapping row                                                                   | When a priority is added in either tool |
| What the step 5 stamp leaves open: two pushes in one second, a Jira edit between our write and the read, an echo on exactly `.000`, and two inbound jobs on one issue. The full fix is to hydrate Jira deliveries like Asana's and lock the row for the comparison | Version 2, by the owner's decision      |
| Remembered filters and sort, and a Priority filter                                                                                                                                                                                                                 | Version 2                               |
| Merging to `main` must also run `manifest/build-08/destructiveChangesPost.xml`, or the development org keeps three dead card bundles                                                                                                                               | At merge                                |
| The git committer identity on this machine; test edits in several Jira and Asana titles, and DOPP-17 left on no priority                                                                                                                                           | Before launch                           |
| The public subtitle is empty, by the owner's decision                                                                                                                                                                                                              | When the owner writes it                |
| Lighthouse best practices 96, not 100: the site root's favicon 404s. The site template's "Skip to Main" link sits outside every landmark. Neither is the board's                                                                                                   | If the template or site assets change   |
| A Jira edit can outlast the 10-second callout timeout; the push then fails though Jira applied it, and Retry recovers                                                                                                                                              | If Jira timeouts recur                  |
| Transient push failures are not retried automatically; the same field saved twice quickly can go out twice, deliberately                                                                                                                                           | Informational                           |
| `AsanaAdapter`'s callout log rows carry no `Work_Item__c`; the Asana format "Article / paper" has no type mapping                                                                                                                                                  | Next time the Asana adapter is touched  |
| Touch drag-and-drop                                                                                                                                                                                                                                                | Version 2                               |
| Flat items' unbounded Done column; Jira's `STATUS_ALIASES`; unresolved parent references never back-filled                                                                                                                                                         | Carried from builds 06-08               |

---

## Verified

**By the build, against the scratch org and live Jira and Asana**

- Inbound from both sources, every value and none, each change followed in 5-9 seconds; an unknown
  id left alone and logged, and a pending priority held back (Apex).
- Outbound through `saveDetails`, the board's own server path: each save one call carrying only
  the priority, confirmed by Jira's changelog and by Asana's change events; each echo applied and
  stopped; each card settled Synced.
- The backfill: every item matching its source, a second run writing nothing, no push queued.
- The stamp: Jira's `updated` stored to the second after each push, and a stale echo, re-delivered
  on purpose, Ignored.
- The public board, logged out: badges on every card with a priority and none on the two without;
  both sorts in every column with ties by key; the toolbar within 375px; a Jira priority change
  shown in 20 seconds and cleared in 26; zero axe violations in nine states; no request on a sort
  change; HTTP 200 and one query.

**By the owner, 9/26** (`docs/build-09/verification.md`)

- The open card's Priority select on WI-0003, screenshotted: the board's choices, then No priority.
- No priority saved and seen in Jira as the en dash - blank reaches Apex from the browser - then
  Medium, High and none again, through a timeout that Retry recovered.
- The keyboard walkthrough with Priority between Due and Save changes.

**Left for the owner:** a priority changed in Jira or Asana reaching the internal board without a
refresh; the internal board's Sort; a priority saved from an Asana card.

---

## Next: launch

Build 09 was the last build before version 1. What stands between here and launch is outside it by
design: merging `feature/first-branch` to `main` with build 08's destructive changes, the move to
the Developer Edition org - with the webhooks re-registered and, if the Jira site or Asana workspace
changes, the priority ids re-read and the mapping rows edited (the handoff's section 6 has the
recipe) - and the test data cleaned up. Version 2 starts with hydrating Jira deliveries, the Big
Object archive that `IntegrationDataPurge` makes necessary, remembered filters and sort, a Priority
filter, and touch drag-and-drop.
