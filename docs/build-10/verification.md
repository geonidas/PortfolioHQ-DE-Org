# Build 10 — Verification

The spec's acceptance criteria, what the build verified and how, and the owner's checks - the ones
that need a signed-in session or a person's eyes. The build's column ran against the scratch org:
the internal board as the owner, pressing the real button, and the public board logged out, in a
fresh headless browser. No Jira or Asana call was made; none was needed.

Final state: `feature/first-branch` at build 10 step 4 (`cf43c18`) plus this step's documents, site
republished 2026-09-27 01:29:12 UTC (`08PE200000bFUoVMAW`), **no epic featured**.

## Acceptance criteria

| #   | Criterion                                                                                                                                                     | Verified by the build                                                                                                                                                                                                                                                                                                                                                                                                                              | Owner                                                                                             |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| 1   | All Apex and Jest tests pass; eslint and prettier clean                                                                                                       | 501/501 Apex (RunLocalTests, run `707E200002Dig26` - its summary reads 502, counting `FeaturedEpicServiceTest`'s `@TestSetup` as a result row); 316/316 Jest; eslint and prettier clean                                                                                                                                                                                                                                                            | -                                                                                                 |
| 2   | HTTP 200 and one SOQL query for an anonymous visitor, with and without a featured epic, on load and per poll                                                  | Logged out, with a trace on the site guest user, four calls: featured, load 01:32:35 and poll 01:33:05; none, load 01:33:27 and poll 01:33:57 UTC. Each logged one `SOQL_EXECUTE_BEGIN` and "Number of SOQL queries: 1 out of 100", and each answered HTTP 200. In Apex, `PublicBoardControllerTest.oneQueryWithAnEpicFeatured`, which also asserts that the setting was really read                                                               | -                                                                                                 |
| 3   | The button appears only on epic cards, only on the internal board, only with `Portfolio_HQ_Feature_Epic`; featuring a second epic replaces the first          | Live as the owner (step 3): Feature on WI-0000, then on WI-0001, answered "in place of WI-0000", and WI-0000's indicator went; an open flat card had no button. Apex: without the permission both methods refuse, by exact message, and change nothing; the board says `canFeatureEpic` only for a holder. Jest: the button appears only on epic cards and only with the ability; the public board passes its cards no ability (build 08 guard)    | **Pending:** feature an epic, then another; open a Story or a flat card and see no button         |
| 4   | Featuring or clearing queues no push, changes no `Work_Item__c` and makes no callout                                                                          | Apex guards, each proved by a planted write: exactly one row written (the setting's), no job queued, nothing staged and no work item changed. The same, run as a Standard User holding the permission set. Live, across every check in steps 1-5: `Integration_Log__c` - one row per callout - stayed at LOG-00160, `WorkItemSyncQueueable` jobs stayed at 34, and WI-0000, WI-0001, WI-0002 and WI-0015 kept `SystemModstamp` 2026-09-26 01:56:11 | -                                                                                                 |
| 5   | With an epic featured, the public board opens in Tasks, showing that epic's items and the "Showing tasks from" line; flat items appear exactly as in build 09 | Audit, logged out, at both sizes: opens on Tasks, sentence "Showing tasks from…", 10 cards - WI-0000's four and the six flat ones, as build 09 showed. Jest: every combination of state, view and source, with flat work pinned to build 09's layout and compared with the same payload stripped of build 10's fields                                                                                                                              | **Pending:** a private window on the site with an epic featured                                   |
| 6   | With none featured, or an unresolved one, the public board opens in Epics, and Tasks shows the note                                                           | Audit, logged out, at both sizes: opens on Epics; Tasks shows "No epic is featured right now, so no epic tasks are shown." with WI-0002, WI-0003, WI-0005 and WI-0006 absent. Jest: "unresolved" (a featured epic retyped by a delivery) behaves as none. Apex: a deleted, retyped or unpublished epic reads as none                                                                                                                               | **Pending:** a private window on the site with none featured                                      |
| 7   | A featured-epic change reaches an open public board within about 30 seconds without changing its view                                                         | Live, logged out (step 4): a page left open on Tasks followed a clear in **21 s** and a re-feature in **29 s**, on Tasks both times. Jest: a poll that changes, clears, or first finds a featured epic never moves the view                                                                                                                                                                                                                        | **Pending:** leave a private window open on the board, feature or remove an epic, watch it follow |
| 8   | The featured epic shows the indicator in the Epics view on both boards, with an accessible name                                                               | Internal, live: "★ Featured on the public board", with the card's header `aria-describedby` the indicator - resolved in Lightning's own DOM. Public, audit: exactly one epic carries "★ Featured". Jest and sa11y on the card, featured, closed and open                                                                                                                                                                                           | Optional: a screen reader on the internal board, tabbing to the featured epic                     |
| 9   | A Source filter that excludes the featured epic's source shows the source note, naming no vendor in component source                                          | Audit, logged out, at both sizes: "The featured epic's tasks are under Jira. Choose Jira or All sources to see them." - the label from the payload. The vendor-name scan (`lwc/__tests__/vendorNeutrality.test.js`) passes                                                                                                                                                                                                                         | -                                                                                                 |
| 10  | Zero sa11y violations; zero axe violations in the audit states; Lighthouse no lower than baseline on any score                                                | sa11y in every changed component's suite. `audit-public-board.mjs`: zero axe violations in the board across **14** states, colour contrast included, and every content check clean; the site template's own "region" finding reported, not failed, as in build 09. Lighthouse below                                                                                                                                                                | -                                                                                                 |

## Keyboard-only walkthrough, internal board

The public board's walkthrough is automated in the audit: 15 stops at desktop width and 17 at
375px, every one ringed. The internal board needs a signed-in session. With the mouse set aside, in
the Epics view:

1. Tab to an epic card's header; Enter opens it.
2. Tab: **Feature on public board** (or **Remove from public board** on the featured epic), then
   **Open record**. Both show a dark 2px outline.
3. Enter on the button: the line under it says "Saving…" and then the server's answer; the button
   keeps focus and changes its label, and the indicator appears or goes.
4. Escape closes the card with focus back on its header.

The order was checked live in step 3 - header, button, Open record - and in Jest.

**Owner:** pending.

## Lighthouse, after

Same commands and conditions as `docs/build-09/baseline.md`: Lighthouse CLI 13.5.0, the public
board, logged out in a fresh headless incognito profile, three runs each, the median shown. Taken
2026-09-27 01:35-01:47 UTC, after the final republish, in two states of the featured epic set by
script: WI-0000 featured, where the board opens on Tasks as the baseline's did, and none, where it
opens on Epics - the state a new org starts in.

| Run                               | Date | Performance | Accessibility | Best practices | SEO |
| --------------------------------- | ---- | ----------- | ------------- | -------------- | --- |
| Baseline, desktop                 | 9/25 | 97          | 100           | 96             | 82  |
| Baseline, mobile                  | 9/25 | 71          | 100           | 96             | 82  |
| After build 10, featured, desktop | 9/27 | **96**      | 100           | 96             | 82  |
| After build 10, featured, mobile  | 9/27 | 72          | 100           | 96             | 82  |
| After build 10, none, desktop     | 9/27 | 97          | 100           | 96             | 82  |
| After build 10, none, mobile      | 9/27 | 71          | 100           | 96             | 82  |

Individual runs, performance only (the other three scores were the same on every run): featured
desktop 96, 96, 94; featured mobile 73, 72, 72; none desktop 97, 97, 97; none mobile 71, 71, 70.

**Criterion 10 is not met on one score:** desktop performance with an epic featured is one point
under the baseline. Accessibility, best practices and SEO are level in every state. Every run, like
every baseline run, warned that the page loaded too slowly to finish within the time limit, and the
same state on mobile scored above the baseline, so this may be run-to-run noise - three runs cannot
show it either way. Recorded as measured; the owner decides whether it needs more runs.

## A data correction, after the checks

On 2026-09-27 the owner reported that DOPP-16 is an Epic in Jira. Salesforce held WI-0002 as a
Story under WI-0000 - the build 06 seed script's doing, never overwritten because no delivery for
DOPP-16 had arrived (`Source_Type__c` empty). The owner ran the correction themselves (the build's
session was not permitted to edit org data): `Type__c` Epic and no parent, outbound suppressed,
though neither field is pushed. Checked read-only afterwards: WI-0002 Epic, no parent, Synced,
nothing pending; `Integration_Log__c` still at LOG-00160; 34 `WorkItemSyncQueueable` jobs. DOPP-16 now
has its own epic card and Feature button, WI-0003 counts under it, and WI-0000's public count falls
from 4 to 2. Every result above was taken before the correction.

## Commands

```bash
# Tests
sf apex run test --target-org MyScratchOrg --test-level RunLocalTests --result-format human
npm run test:unit
npm run lint
npm run prettier:verify

# The public board, logged out: fourteen states, and it features WI-0000 then none and puts back
# what it found. --shots saves each build 10 state
node scripts/audit-public-board.mjs --shots=docs/build-10/screenshots

# Screenshots at desktop width and a true 375px
node scripts/capture-public-board.mjs docs/build-10/screenshots <label>

# Feature an epic, or none
sf apex run --file scripts/apex/set-featured-epic.apex --target-org MyScratchOrg
sf apex run --file scripts/apex/clear-featured-epic.apex --target-org MyScratchOrg
```

Screenshots in `docs/build-10/screenshots`: `step-03-*` (the internal board, live),
`step-04-*` (each public state, from the audit) and `step-05-featured-*` / `step-05-none-*` (the
final board, desktop and 375px).
