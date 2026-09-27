# Build 10 — Featured epic

**Status:** complete and verified in the scratch org. The public board was checked logged out, and
the internal board as the owner, pressing the real button. No Jira or Asana call was made, by
design. The owner's own checks are pending: see `docs/build-10/verification.md`.

The owner can now choose one epic to feature on the public board, from a button on that epic's
card on the internal board. With an epic featured, the public board opens on Tasks and shows that
epic's tasks, with a sentence naming it. With none featured, it opens on Epics, and Tasks says no
epic tasks are shown. The featured epic carries an indicator on both boards: "Featured on the
public board" inside, "Featured" in public. A change reaches an open public board on its next
poll, within about 30 seconds, and never moves the visitor to another view.

Most of the plan survived contact with the org, but four things changed it. Step 0 found that
the spec's own reading of membership, "direct children, as its card counts them", named two
different sets, and that its public `featuredEpicId` would have published the first Salesforce id
an anonymous visitor ever received. It raised five questions, and the owner took all five
recommendations. Step 3 found that step 1's service could not write its own setting for anyone but
an admin, because every step 1 test had run as the admin. And step 4 found that 39 existing tests
assumed the Tasks default, which decision 7 had just changed. All of it is below, with the build's
own mistakes.

**Verified:** 501 Apex tests, 100% pass (461 at the end of build 09); 316 Jest (271); eslint and
prettier clean; zero axe violations in the public board across fourteen states, the featured epic's
five among them, at both sizes; no view, source or sort change reaches Apex; the public board
answers an anonymous visitor with HTTP 200 and one SOQL query, with and without a featured epic, on
load and on a poll; Lighthouse level with the baseline on every score but one - desktop performance with an epic featured, 96 against 97 (see verification).

Six commits on `feature/first-branch`, one per step. No separate branch.

---

## What build 10 delivered

**The setting, the permission and the service (step 1)**

- `Featured_Epic__c`: a hierarchy custom setting with Protected visibility. Only its org default is
  used, so one epic is featured by construction. `Epic_Id__c` is Text(18), because a custom
  setting cannot hold a lookup. It is data, not metadata, so nothing is featured after a deploy.
- `Portfolio_HQ_Feature_Epic`: a custom permission, granted through `Portfolio_HQ_Developer`.
- `FeaturedEpicService`. It reads the stored Id with no query, reads it back resolved, features an
  epic and clears it. One rule decides what can be featured: an epic as `EpicRollup.isEpic` defines
  one, public, under a public project. Setting uses the rule to refuse, with a reason. Reading back
  uses it to return none, without clearing. The service writes the setting's row and nothing else:
  no work item, no push, no adapter.
- `scripts/apex/set-featured-epic.apex` and `clear-featured-epic.apex`, for live checks and for the
  move to the Developer Edition org.

**The payloads (step 2)**

- Internal: `featuredEpicId`, and `isFeatured` on each epic. Public: `isFeatured` on each epic, and
  `inEpic` and `inFeaturedEpic` on each card - answers, with no identifier.
- Resolved against the rows each controller already loaded, from the cached setting, at no extra
  query. On the public board, an epic the visitor cannot see is none.
- `EpicRollup` takes the featured epic. A featured epic moved to Done keeps its card past the cap
  of three finished epics, and its tasks stay in the public Tasks view while it is featured.
  Membership is as the card counts it.

**The internal board (step 3)**

- `featureEpic(Id)` and `unfeatureEpic(Id)`, each checking the custom permission first. Remove
  clears only if its epic is still the featured one.
- In the open epic card: "Feature on public board" or "Remove from public board", placed before
  Open record. A status line says "Saving…", then the server's answer, and the board refreshes
  itself.
- The indicator: a bordered chip under the meta line, in words, which the card's header is
  described by.

**The public board (step 4)**

- The opening view is chosen once, from the first payload: Tasks when an epic is featured, Epics
  when none is.
- The Tasks view filters only epic work, keeping the featured epic's. One sentence under the
  toolbar: "Showing tasks from…", or where the featured epic's tasks are when the Source filter
  hides them, or that no epic is featured.
- "Featured" on the featured epic's card.

**Gates that did not exist before**

- Three service guards - one row written, no push queued, nothing staged - each proved by a planted
  write.
- An Apex test that runs the board's methods as a Standard User holding the permission set, not as
  the admin. It found the step 1 defect.
- `GuestAccessTest` asserts that the site guest holds no custom setting, custom metadata or custom
  permission grant on any set it has, its profile's included. It was proved by planting one.
- A Jest matrix: every combination of featured state, view and source. In each, flat work is
  pinned to build 09's layout and compared with the same payload stripped of build 10's fields.
- The audit sets the featured epic itself and puts it back. Fourteen states, each checked for what
  it shows. The request watcher now covers view and source changes as well as sorts.
- A recipe in the handoff for counting a visitor's queries as the visitor, with a short trace on
  the site guest.

---

## Decisions, and why

The fourteen decisions the owner made before the build are in `docs/adr/build-10-featured-epic.md`,
with their reasoning. In short:

- The featured epic is a custom setting's org default, set by new controller methods behind a new
  permission.
- Only an epic is accepted, and membership comes from `EpicRollup`.
- Flat work is unchanged.
- The Tasks view shows the featured epic's work under a line saying so.
- The board opens on Tasks when an epic is featured and on Epics when none is, on load only.
- A featured epic moved to Done stays featured.
- A source filter that hides the featured epic says where its tasks went.
- The indicator is in `boardEpicCard`, in words.
- A change reaches the public board on its next poll.

Five answers the owner gave at step 0, each written into the decision it amends:

### 1. The public payload carries answers, not an id

The spec gave both payloads `featuredEpicId`, the epic's Id. No public DTO carries a Salesforce
id, and a public test bans the key, so this would have been the first id an anonymous visitor
received. It would also have matched nothing on the client, since no public epic or card carries
one. The public side got `isFeatured` on epics, and `inEpic` and `inFeaturedEpic` on cards. The
internal side keeps `featuredEpicId`.

### 2. Membership is as the card counts it

Decision 4 said "direct children, as its card counts them", and those differ: build 06 made a card
count every item whose nearest epic it is (ADR-011). Today they differ by WI-0003, a Story under a
Story. Counting as the card does keeps the Tasks view under a featured epic equal to the number on
its card.

### 3. A featured epic that is Done keeps its card and its tasks

Build 07 withholds a finished epic's tasks, and build 06 lists only the three newest finished
epics. Left alone, decision 10 would have held in the setting and nowhere on screen. The featured
epic is exempt from both, and every other epic is unchanged.

### 4. Only an epic the public board can show

Setting a private epic would have put "Featured on the public board" on an epic the public board
could never show. The same rule refuses it when setting and reads it back as none.

### 5. The unresolved-parent count stays open

Completing it needs a read from Jira, which this build made none of. It is carried to after the
move.

Six more were made during the build, each in the ADR:

### 6. Remove names its epic

The spec's clear took no argument. On a button, that lets a tab left open after another epic was
featured remove the newer choice. `unfeatureEpic` sends the epic it was pressed on, and a stale
press changes nothing and names the epic that is featured.

### 7. A result says which of three things happened

`refused` joined the result: written, refused with a reason, or unchanged because things are
already as asked. The card shows only a refusal as an error.

### 8. The setting is written in explicit system mode

See "What meeting the live org changed". No grant was widened to fix it.

### 9. The view is chosen once, and the sentence lives in one status region

The first payload picks the view. After that only the visitor does, so decision 9 is structural,
not a rule to remember. The sentence is one `role="status"` element whose words change: it is
announced when they change, and a poll with nothing new announces nothing.

### 10. The empty Tasks view stopped claiming every epic is complete

Build 09 said so because it was then what empty meant. Under the featured filter it often is not.

### 11. The audit sets the featured epic itself

Which epic is featured is org data, so the audit features WI-0000, then none, through the service,
and restores the exact value it found. Build 09's nine states run featured, on the Tasks view they
were written for.

---

## What meeting the live org changed

- **The spec named two sets as one (step 0).** "Direct children" and "as its card counts them"
  differ. Both boards' counts were read three ways - `EpicRollup` in Apex, the rendered Epics view
  logged out, and signed in - and they agree: 2 of 9 inside, 1 of 4 in public.
- **Some hierarchy exists in Salesforce only (step 0).** WI-0005 and WI-0006 hang under WI-0000
  because the build 06 seed script put them there; their Jira payloads carry no parent. WI-0001 is
  an epic only because the same script retyped it. The next Jira delivery for `DOPP-15` carrying
  its issue type would turn it back, and it would then read as none if featured.
- **The unresolved-parent count cannot be finished from the org (step 0).** No field stores an
  unresolved reference, and the purge has aged out the log rows that would have. The 27 stored Jira
  deliveries show none. Only WI-0007 and WI-0009, both private, could be one.
- **The guest reads the setting with no grant (step 2).** This was proved logged out, with a trace
  on the site guest: `storedId()` returned the epic's Id, and the limit line read one query on load
  and on the poll. LWR logs each call twice. The large log, labelled `UniversalPerfLogger`, holds
  the call.
- **A non-admin cannot write a custom setting with plain DML (step 3).** The first test to run the
  board's methods as a Standard User holding `Portfolio_HQ_Developer` failed with "Access to entity
  'Featured_Epic__c' denied". A throwaway probe, validated check-only and never deployed, separated
  the cases:
  - Reading the setting: allowed.
  - A plain insert: refused.
  - The same insert from a `without sharing` class: refused.
  - An explicit `AccessLevel.SYSTEM_MODE` insert: allowed.
  - A `customSettingAccesses` grant: no help.

  The service now writes in explicit system mode, and the grant was reverted. Step 1's comment had
  already claimed system mode; only the admin, who passes either way, had tested it.

- **The deploy queue stalled once (step 3).** A check-only validation sat Pending for twenty
  minutes with nothing else queued. Cancelling it and resubmitting ran at once.

---

- **DOPP-16 was a Story in Salesforce and an Epic in Jira (after the checks).** The owner noticed
  it had no epic card. The seed script had typed it, and no delivery had ever carried its real
  type. The owner corrected it - `Type__c` Epic, parent cleared - after every measurement above.

---

## Mistakes worth recording

- **Step 1 tested only as the admin.** The handoff's "test the identity" trap, again. The service
  was usable by an admin alone, and every test said it was fine. It was caught in step 3, by the
  first test that ran as someone else.
- **Two reserved words.** A local named `type` (step 1, caught before the deploy) and one named
  `number` (step 2, caught by the compiler). Both are on Apex's list.
- **A guard that compared the board with itself (step 4).** The first "flat work as in build 09"
  check compared the rendered board with the same payload stripped of build 10's fields. A planted
  defect showed that the baseline renders through the same component, so a shared defect moves both
  sides. The layout is now pinned as well, and the plant fails six cells.
- **Test harness surprises (step 4).** The test wire adapter hands every emit to every mounted
  board, so mounting the baseline second overwrote the board under test. Jest's `expect` takes no
  message argument. eslint refused conditional expects and an await in a loop.
- **39 tests, and one missed (step 4).** They assumed the Tasks default. My insertion list missed
  one, which failed on the next run.
- **Tooling slips.** A live probe called `getElementById` on a Lightning shadow root, which Lightning
  refuses, after the button press it followed had gone through. The setting was cleared and the run
  repeated. A handoff line pointed to section 1 for the guest's user id, which lists only its
  username. A publish watcher tracked the newest background operation rather than the publish. zsh
  expands a leading `=`, which ate a separator.
- **A run summary that counts one test too many.** `FeaturedEpicServiceTest` is the first class
  here with a `@TestSetup`. The org records a result row for the setup method and the summary counts
  it, so every run since reads one more than there are tests. It was found by diffing the list
  against `ApexTestResult`, and is in the handoff.

---

## Open items carried forward

| Item                                                                                                                                                                                                                                                                                                   | Trigger point                                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------ |
| The unresolved-parent count is incomplete: WI-0007 and WI-0009 could be unresolved or simply parentless, which only Jira can say                                                                                                                                                                       | After the move, when the hierarchy arrives by delivery |
| Salesforce-only hierarchy from the seed script: WI-0005 and WI-0006 under WI-0000, and WI-0001 typed Epic. A Jira delivery for `DOPP-15` carrying its type unmakes that epic. WI-0002 (DOPP-16) was corrected to an Epic with no parent on 9/27, by the owner; rerunning the seed script would undo it | Before launch, in the Developer Edition org            |
| Subtasks are ordinary cards: Jira's Sub-task maps to `Task`, and one under a featured epic would show. None is public today                                                                                                                                                                            | Version 2                                              |
| At 375px the portrait arrows (sticky at mid-screen since build 08) can sit over a column heading when the content above is tall, as with the featured epic's four-line sentence                                                                                                                        | If the portrait layout is revisited                    |
| Other open internal tabs see a featured-epic change only on their next refresh: Change Data Capture does not fire for a custom setting                                                                                                                                                                 | Informational                                          |
| A new priority value added in Jira or Asana is logged and ignored                                                                                                                                                                                                                                      | When a priority is added in either tool                |
| What build 09's stamp leaves open: two pushes in one second, a Jira edit between the write and the read, an echo on exactly `.000`, two inbound jobs on one issue                                                                                                                                      | Version 2, by the owner's decision                     |
| Remembered filters and sort, a Priority filter, touch drag-and-drop                                                                                                                                                                                                                                    | Version 2                                              |
| Merging to `main` must also run `manifest/build-08/destructiveChangesPost.xml`                                                                                                                                                                                                                         | At merge                                               |
| The git committer identity on this machine; test edits in several Jira and Asana titles; priorities changed during build 09's checks                                                                                                                                                                   | Before launch                                          |
| The public subtitle is empty, by the owner's decision                                                                                                                                                                                                                                                  | When the owner writes it                               |
| Lighthouse best practices 96: the site root's favicon 404s. The template's "Skip to Main" link sits outside every landmark                                                                                                                                                                             | If the template or site assets change                  |
| A Jira edit can outlast the 10-second callout timeout; Retry recovers                                                                                                                                                                                                                                  | If Jira timeouts recur                                 |
| Transient push failures are not retried automatically; the same field saved twice quickly can go out twice, deliberately                                                                                                                                                                               | Informational                                          |
| `AsanaAdapter`'s log rows carry no `Work_Item__c`; the Asana format "Article / paper" has no type mapping                                                                                                                                                                                              | Next time the Asana adapter is touched                 |
| Flat items' unbounded Done column; Jira's `STATUS_ALIASES`; unresolved parent references never back-filled                                                                                                                                                                                             | Carried from builds 06-09                              |

---

## Verified

**By the build, against the scratch org**

- The service and both controllers, in Apex, as the admin and as a Standard User holding the
  permission set. Each change writes exactly one row, queues nothing and stages nothing, each
  proved by a planted write that failed the guards.
- The internal board, live as the owner, pressing the real buttons: feature WI-0000, replace it with
  WI-0001, remove it, and find no button on a flat card. The indicator's description resolves in
  Lightning's own DOM, and the tab order is header, button, Open record.
- The public board, logged out: fourteen audit states with zero axe violations, the right content
  in each, the sentence inside 375px below the toolbar, and no Apex request on a view, source or
  sort change. A page left open followed a clear in 21 seconds and a re-feature in 29, staying on
  Tasks both times.
- One SOQL query per anonymous call, featured and not, on load and on a poll, from the guest's own
  debug logs. HTTP 200 throughout.
- Across every live check, nothing but the setting moved. `Integration_Log__c` stayed at LOG-00160,
  `WorkItemSyncQueueable` jobs stayed at 34, and the touched cards kept their 9/26 01:56:11
  timestamps.

**By the owner** - pending; see `docs/build-10/verification.md`.

---

## Next: launch

Build 10 closes version 1. What stands between here and launch is outside it by design:

- Merge `feature/first-branch` to `main`, with build 08's destructive changes.
- Move to the Developer Edition org, following the handoff's section 6.
- Clean up the test data.

On the new org the featured epic is data and does not travel. Until the owner features one - with
the button, which needs `Portfolio_HQ_Developer` assigned, or with
`scripts/apex/set-featured-epic.apex` - the public board opens on its Epics view, and its Tasks
view shows only flat work and orphans.
