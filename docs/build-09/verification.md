# Build 09 — Verification

The spec's acceptance criteria, what the build verified and how, and what is left for the owner -
the checks that need a signed-in session. Everything in the build's column ran against the scratch
org and live Jira and Asana; the public board was checked logged out, in a fresh headless browser.

## Acceptance criteria

| #   | Criterion                                                                                                                                      | Verified by the build                                                                                                                                                                                                                                                                                                                                                                                 | Owner                                                                                                                                                                   |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | All Apex and Jest tests pass; eslint and prettier clean                                                                                        | 461/461 Apex (RunLocalTests, run 707E200002DckkY); 271/271 Jest; eslint and prettier clean                                                                                                                                                                                                                                                                                                            | -                                                                                                                                                                       |
| 2   | The public board answers an anonymous visitor with HTTP 200 and one SOQL query, on load and per poll, with the Sort control in use             | HTTP 200 logged out after the final republish. One query: `PublicBoardControllerTest` (with priority in the query, step 5), and the payload read in step 5 used 1. A poll is the same parameterless call. The Sort is client-side: `audit-public-board.mjs` counted **0 requests** while the sort changed, at both sizes - and the same watcher counted Refresh's 1 Apex request, so the zero is real | -                                                                                                                                                                       |
| 3   | A priority changed in Jira or Asana, including to none, reaches the record, the internal board without a refresh, and the public board in ~30s | Record: Jira High, `–`, Medium and Asana High, Low, empty, each followed in 5-9s (step 2). Change Data Capture carries `Priority__c`, set and cleared (step 1). Public board, logged out: DOPP-17 set to High in Jira showed "High" on WI-0003 after **20s**; set to `–`, the badge left after **26s** (step 8)                                                                                       | **To check:** change a priority in Jira or Asana with the internal board open, and see it change without a refresh                                                      |
| 4   | A priority edited on the internal board updates Jira and Asana with only the priority changed, including none                                  | Through `saveDetails`, the board's own server path (step 3): Jira `{"priority":{"id":…}}` alone for High, none (`10000`), Medium - Jira's changelog shows those three and nothing else; Asana `custom_fields` alone, the option gid then `null`. A title-and-priority save is one call carrying both (Apex)                                                                                           | **Passed 9/26 for Jira** from the open card: No priority reached Jira as `10000`, Medium as `3`; a timeout on the way recovered with Retry. **To check:** an Asana card |
| 5   | An unknown inbound priority leaves the field unchanged and is logged                                                                           | Apex, both sources: an unmapped Jira id (Highest) and an unmapped Asana option are not carried, log one Inbound warning naming the id, and the rest of the delivery applies; the processor keeps Medium while title and status change. Not exercised live: it needs a fourth priority added in Jira or Asana                                                                                          | -                                                                                                                                                                       |
| 6   | After the backfill, every item's priority matches its source; a second run changes nothing                                                     | First run: priority set on 18, Jira 14 Medium, Asana High 3 / Medium 1 / Low 1 / none 1. Second run `updated=0`. Cross-checked against direct reads of every issue and task: 20 of 20 agree. No push queued, nothing pending (step 4)                                                                                                                                                                 | -                                                                                                                                                                       |
| 7   | Both boards open sorted by Due date and switch to Priority; blanks last; ties as decided                                                       | Jest on both boards and the model, every view and source, Los Angeles time. Public, live: both sorts in every column, ties by key (WI-0015 before WI-0016, both High and due 27 Sep) (step 7)                                                                                                                                                                                                         | **To check:** the internal board opens on Due date and re-sorts by Priority                                                                                             |
| 8   | In the Epics view, epics keep their order and their items sort                                                                                 | Jest on both boards. Epic cards list no items, so the items that sort are the cards passing through, after the epics - ADR, "Three readings" (step 7)                                                                                                                                                                                                                                                 | -                                                                                                                                                                       |
| 9   | Cards with a priority show the badge; cards without show none; the badge's accessible name includes "Priority"                                 | Jest: the badge, none for none, the spoken line "…, Priority: High". Public, live: every card with a priority shows one, WI-0020 and WI-0003 (none) show none                                                                                                                                                                                                                                         | The step 6 screenshot: WI-0003 open with no priority and no badge                                                                                                       |
| 10  | Portrait at 375px shows the toolbar without overflow; landscape unchanged                                                                      | Device emulation at 375: document 375 of 375, toolbar 327 of 327; Sort wraps to a second row. Desktop: the three controls on one line. Screenshots `step-07-*` and `step-08-*`                                                                                                                                                                                                                        | -                                                                                                                                                                       |
| 11  | Zero sa11y violations; zero axe violations in the audit states; Lighthouse accessibility no lower than baseline                                | sa11y in every Jest suite, nothing pinned. `audit-public-board.mjs`: zero axe violations in the board across **nine** states, both sorts at both sizes, contrast included; every keyboard stop ringed, 15 at desktop and 17 at 375. Lighthouse accessibility **100** on desktop and mobile, level with the baseline - below                                                                           | -                                                                                                                                                                       |

## Keyboard-only walkthrough, internal board

The public board's walkthrough is automated in `scripts/audit-public-board.mjs` (both sizes, every
stop ringed). The internal board needs a signed-in session. With the mouse set aside:

1. Tab from the page into the board: View, then Source, then **Sort** (build 09 step 7), then each
   card's header in column order. Every stop shows a dark 2px outline.
2. Enter on a card header opens it; the card lifts and its stripe widens - not the same as the
   outline on a focused, closed card.
3. Tab through the open card: Retry (on a Failed card only), the Move to buttons, Title, Start
   (Jira only), Due, **Priority** (build 09 step 6; for a source whose `Board_Source__mdt` says it
   holds one - Jira and Asana both do), Save changes, Cancel, Open record. Every stop outlined.
4. In Priority, the arrow keys move between the choices - the board's in priority order, then No
   priority - and the choice is not saved until Save changes.
5. Escape anywhere in the open card closes it and puts focus back on its header.
6. Move a card with a Move to button: focus follows the card to its new column, into its sorted
   place.
7. In a portrait window, Tab reaches the two arrows before the cards, and Enter on an arrow moves
   the column.

The owner reported the walkthrough passed on 9/26, with the step 6 editor in place; Sort (step 7)
came after. Jest holds the open card's order - Title, Start, Due, Priority, Save changes, Cancel -
in `boardCard.test.js`, "sits between the dates and Save".

## Lighthouse, after

Same conditions and commands as `baseline.md`: Lighthouse CLI 13.5.0, the public board, logged out
in a fresh headless profile, three runs each, the median shown. Taken 2026-09-26 03:28-03:32 UTC,
after the final republish.

| Run                     | Date | Performance | Accessibility | Best practices | SEO |
| ----------------------- | ---- | ----------- | ------------- | -------------- | --- |
| Baseline, desktop       | 9/25 | 97          | 100           | 96             | 82  |
| Baseline, mobile        | 9/25 | 71          | 100           | 96             | 82  |
| After build 09, desktop | 9/26 | 97          | 100           | 96             | 82  |
| After build 09, mobile  | 9/26 | 71          | 100           | 96             | 82  |

Every score is level with the baseline. The individual runs: desktop 97, 96, 97 on performance and
the same on everything else; mobile 72, 71, 71. The failed audits are the baseline's four and none
of them the board's: one console error, the site root's `/favicon.ico` answering 404; missing
source maps, weight 0; no meta description; the template's uncrawlable "Skip to Main" link.

## Commands

```bash
sf apex run test --target-org MyScratchOrg --test-level RunLocalTests --result-format human
npm run test:unit
npm run lint
npm run prettier:verify
curl -s -o /dev/null -w '%{http_code}\n' https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board
node scripts/audit-public-board.mjs
node scripts/capture-public-board.mjs docs/build-09/screenshots <label> [WI-0005]
sf apex run --file scripts/apex/check-priority-sources.apex --target-org MyScratchOrg | grep '>>>'
```
