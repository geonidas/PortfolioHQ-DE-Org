# Build 08 — Board redesign, in-card editing, live updates

**Status:** complete in the scratch org, pending the owner's Lighthouse run and verification list
(see "Verified"). Both boards were redesigned and the internal board made fully interactive: every
card names its source with a colour accent, both boards filter by view and source, cards open in
place, the internal board edits title, start and due date and pushes each edit to Jira or Asana,
drags cards between columns, retries a refused push and links admins to the record, and portrait
windows show one column at a time. The internal board updates live; the public board re-reads
every 30 seconds while someone is looking.

Meeting the live org mattered more than the plan expected. Five defects were found only by
driving the real thing - a double push, an Epics count that counted flat items as epics, two
portrait layout faults, and a date line that wrapped with a stray separator - and two of the
owner's first-use requests reshaped drag-and-drop. Two more were the build's own tests and plans
being wrong: a guard test that could not see what it guarded, and a design-plan CSS fallback that
could never fall back. All are recorded below rather than smoothed over.

**Verified:** 409 Apex tests, 100% pass (316 at the end of build 07); 232 Jest (72); eslint and
prettier clean; zero axe violations in the public board across seven states in a real browser,
colour contrast included; site republished; the public board answers an anonymous visitor with
HTTP 200 and one SOQL query, on load and on every poll.

Ten commits on `feature/first-branch`, one per step after step 0.

---

## What build 08 delivered

**Data and inbound (step 2)**

- `Source_Created__c`, `Start_Date__c`, `Due_Date__c` on `Work_Item__c`, filled from both sources;
  `Description__c` filled inbound only.
- `Board_Source__mdt` and a rewritten `BoardSourceRules`: label, accent token, start-date support
  and epic condensing per source. The Jira start field id in a `Field_Mapping__mdt` row.
- `IsoDate` - strict `YYYY-MM-DD` - and "carried" flags on `InboundChange`, so a cleared date
  clears.

**Outbound field sync (steps 3, 7, 8)**

- `SyncField`, `SyncFields`, `Pending_Push_Fields__c`, `Sync_Error__c`; `IWorkItemAdapter.push`,
  taking the record and the fields to send, replacing `updateStatus`; inbound skipping fields
  still pending.
- Push jobs that own the fields their own save staged (step 7), and Retry as a Failed-to-Pending
  save (step 8).
- `WorkItemBoardController.saveDetails` and `retryPush`; `changeStatus` unchanged.

**The boards (steps 5-9)**

- Both payloads carry source label, accent token and dates; the internal one became a DTO with the
  public one's property names. `EpicRollup` gives both boards one set of epic rules.
- Shared components: `boardCard`, `boardEpicCard`, `boardToolbar`, `boardColumns`; shared modules
  `boardModel`, `boardLayout`, and the CSS-only `boardTheme`. The three card components of builds
  04-07 were deleted, in source and - through `manifest/build-08/destructiveChangesPost.xml` - in
  the org.
- Internal: Change Data Capture live updates, open cards with Move to, an editor, Retry and an
  admin record link behind the `Portfolio_HQ_Open_Record` custom permission; drag-and-drop with a
  fine pointer in landscape. Public: polling, a subtitle design attribute, read-only open cards.
- Portrait: one column at a time, snap and swipe, named arrows, a position line, opening on In
  Progress.

**Gates that did not exist before**

- sa11y on every component, no pinned violations left; a vendor-name scan of all LWC source; a
  guest-bundle graph walk that fails if the public board can reach the internal controller or
  `lightning/empApi`; a test holding the portrait media query to one value in JS and CSS.
- `scripts/capture-public-board.mjs` and `scripts/audit-public-board.mjs`: guest screenshots at a
  true 375px, and axe plus a keyboard walkthrough in a real browser.

---

## Decisions, and why

All nine are in `docs/adr/build-08-board-redesign.md`; these are the reasons in brief.

### 1. The public board names the vendor

The portfolio's point is the integrations; hiding them hid the thing the page exists to show.
Build 07's rule survives in the half that mattered: the client never branches on a vendor, and a
scan fails the suite if one appears in LWC source.

### 2. One card for both boards, abilities granted by the board

The boards differed only in what a card could do, so that became `abilities` passed by the
internal board and never by the public one. Opening a card turned out not to be an ability - the
public board has open cards too - and step 7 amended the decision to say so.

### 3. A drop is Move to by another route, and Retry is a save

No optimistic move and no new Apex for drag; Retry lives in the trigger so every client retries
the same way and no controller calls the sync service.

### 4. One layout component, with the boards' own columns slotted into it

Portrait behaves identically on both boards because it is one component, and each board keeps its
own cards, drop targets and abilities.

### 5-9. Metadata for per-source answers; push exactly what changed; dates as calendar strings; descriptions inbound only; live internally, polled publicly

The step 0 decisions. The one worth repeating here is the polling "middle option": a Developer
Edition site has ten minutes of server time a day, and a public tab left open would otherwise
spend it alone.

---

## What meeting the live org changed

- **A double push (step 7).** Two saves seconds apart made two jobs, and the second resent the
  first's fields because the first job's write-back was waiting on a row lock. Harmless on the
  day - both calls idempotent - but a step 3 design race. Fixed by per-save field ownership, with
  two rules so no field is stranded; proven by switching the fix off and watching four tests fail,
  then verified live with the race reproduced (a job that waited 22 seconds in the queue).
- **Drag by the edge, and full-height columns (step 8).** The owner's first live try: the accent
  stripe is where a hand reaches for a drag, and a short column could not be reached from far down
  a long one.
- **Portrait columns (step 9).** The first deploy had two faults: every column stretched to the
  tallest, seen in the 375px capture as a long empty column; and columns sized so the first and
  last could never centre - 22px short, measured in headless Chrome and confirmed on a local copy
  before the fix went out.
- **The Epics count (step 6)** called six flat Asana items "6 epics" once the Source filter made it
  visible. Now "2 epics, 6 items".
- **The canary (step 7).** WI-0011 showed Pending for two builds because the seed wrote Pending and
  a record with no remote record can never push. The payload stopped showing it in step 5; a script
  cleared the record in step 7; the seed no longer writes it.

---

## Verdict on build 07's bets

| Build 07 said                                               | What happened                                                                                                                                           |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "The board branches on a boolean, not a vendor"             | **Kept, and made enforceable.** The public board now shows the vendor's name as data, and a scan fails on a vendor literal in any component             |
| Epic card title truncation, carried from build 06           | **Closed** in step 6, because there was one epic card to fix                                                                                            |
| Flat items' Done column grows unbounded                     | **Still open**, deliberately out of scope                                                                                                               |
| Jira's `STATUS_ALIASES` beside Asana's `Field_Mapping__mdt` | **Still open**, deliberately out of scope; build 08 put the new Jira start field id in `Field_Mapping__mdt`, so the table grows rather than the aliases |

---

## Mistakes worth recording

- **A guard test that was blind for a step.** Step 6's "no control but Refresh, View, Source" test
  mapped controls to attributes and compared with `toEqual`, which skips `undefined` array
  entries - so any control without those attributes vanished from the check. Step 6's commit said
  the list was asserted exactly. Step 7's disclosure buttons passed it untouched, which is how it
  was found. Now `toStrictEqual`, every control named, and proven by planting a link.
- **A CSS fallback that could not fall back.** The design plan declared a custom property twice,
  hex then `color-mix`, as a fallback. Custom properties accept anything, so the second always wins.
  `@supports` is the fallback; found before any code shipped, while building step 6.
- **A time-zone pin that pinned nothing.** Setting `TZ` inside a Jest file does nothing - Jest hands
  each file a copy of `process.env` - and the first attempt passed only because the build machine
  is already behind UTC. Caught by running under Tokyo and London; the pin is in `jest.config.js`.
- **Two false screenshots and one false alarm.** Headless Chrome's `--window-size` will not go
  below about 500px, so the first "375px" capture was a cropped 500px page; and the in-app browser
  pane, while hidden, paints no frames, so it neither scrolled nor fired scroll events and looked
  like a broken layout. Both recognised; the capture script now emulates the device, and portrait
  was verified in headless Chrome.
- **Help text that overpromised.** The Failed note first said "Saving again retries it"; a save with
  nothing changed saves nothing. Caught in review, before Retry existed to make it true another way.
- **The same limits as ever.** `PermissionSet.description` over 255 characters (268) in step 5;
  `update` as a variable name and Prettier splitting a static call chain into "Variable does not
  exist" in step 3; the scheduled sweeper locking every class in its dependency graph against
  deploys in steps 2 and 3. All in the handoff; all hit again anyway.
- **Deploying the `lwc` folder whole fails** on `lwc/__tests__`, which holds suite-wide tests and
  belongs to no bundle. Found by step 7's first validation, refused before a test ran.

---

## Open items carried forward

| Item                                                                                                                                     | Trigger point                          |
| ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| The public subtitle is empty; the copy is the owner's. The handoff says how to set it without a click-only change                        | Before launch                          |
| Merging to `main` must also run `manifest/build-08/destructiveChangesPost.xml`, or the development org keeps three dead card bundles     | At merge                               |
| The site template's "Skip to Main" link sits outside every landmark and uses the browser's default ring. The template's, not the board's | If the template is replaced            |
| Transient push failures are not retried automatically; Retry or a saved change does it                                                   | If transient failures become common    |
| The same field saved twice quickly can go out twice, deliberately                                                                        | Informational                          |
| `AsanaAdapter`'s callout log rows carry no `Work_Item__c`                                                                                | Next time the Asana adapter is touched |
| Touch drag-and-drop and remembered filter selections                                                                                     | Version 2                              |
| Test edits in several Jira and Asana titles; the git committer identity on this machine                                                  | Before launch                          |
| Flat items' unbounded Done column; Jira's `STATUS_ALIASES`; unresolved parent references never back-filled                               | Carried from builds 06-07              |

---

## Verified

**By the build, against the scratch org and live Jira and Asana**

- Inbound: created, start and due dates and descriptions arriving from both sources, through the
  backfill and live webhook deliveries. That a cleared date clears, and that the trigger refuses an
  Asana start date, are proven by Apex tests rather than by a live edit.
- Outbound: a Jira title, start and due edit sent as one PUT carrying exactly those three fields,
  confirmed by Jira's change history; an Asana title and due edit, with no `start_on` in the body.
- Sync state: Pending until confirmed, Synced after, Failed with the reason; Retry sends the refused
  field once and settles Synced. No push loops: every echo from Jira or Asana applied and stopped.
- Drag-and-drop: three drags, three jobs, each field once; a same-column drop does nothing; drag by
  the edge and a drop from far down a long column both work.
- The public board, logged out: source labels and accents on every card; View and Source in every
  combination with one Apex request; read-only open cards; no drag, no abilities, no control but
  Refresh, the filters, the arrows and the disclosures; portrait one column at a time with every
  column centring exactly; zero axe violations in seven states; a keyboard walkthrough at both sizes
  with a visible ring at every stop and Escape returning focus.
- The canary WI-0011 no longer shows Pending, on the board or the record.

**Pending the owner**

- Lighthouse against `docs/build-08/baseline.md`: accessibility must not fall below 100.
- The verification list in `docs/build-08/verification.md`, including a keyboard-only walkthrough
  of the internal board, which only the owner can sign in to.

---

## Next: launch

Build 08 was the last build before version 1 goes live. What stands between here and launch is the
move to the Developer Edition org - out of scope here by design - with the subtitle written, the
test edits cleaned up and the branch merged. Version 2 starts with the Big Object archive that
`IntegrationDataPurge` currently makes necessary, and can take touch drag-and-drop and remembered
filters with it.
