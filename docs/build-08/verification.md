# Build 08 — Verification

The spec's acceptance criteria, what the build has already verified and how, and what is left for
the owner - the checks that need a signed-in session, a real Jira or Asana edit, or Lighthouse.
The owner's column was filled in from the owner's report of 9/25. Nothing failed. The public
subtitle is left empty by the owner's decision.

## Acceptance criteria

| #   | Criterion                                                                                                                  | Verified by the build                                                                                                                                                                          | Owner                                                                                                                                         |
| --- | -------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | All Apex and Jest tests pass; eslint and prettier clean                                                                    | 409/409 Apex (step 8 validation, 0AfE200000qJDurKAG; no Apex since); Jest, eslint and prettier on the final commit                                                                             | Run by the build: Jest, eslint and prettier before each step, Apex in each validation                                                         |
| 2   | The public board answers an anonymous visitor with HTTP 200 and one SOQL query, on load and per poll                       | `PublicBoardControllerTest` asserts one query; a poll is the same parameterless call (Jest asserts the wire config stays `{}`); live, one Apex request per load and none per filter change     | The board served logged out for the owner's Lighthouse runs (9/25)                                                                            |
| 3   | Every card on both boards shows its source label and accent; no vendor literal in LWC                                      | Public: every card, live, logged out. Vendor scan in Jest. Internal: the owner's step 6-9 screenshots                                                                                          | -                                                                                                                                             |
| 4   | Filters work on both boards in every View × Source combination                                                             | Public: Tasks and Epics × All, Jira, Asana, live, with correct counts ("2 epics, 6 items"). Both boards: Jest                                                                                  | Not reported separately; Jest filters both views by source on both boards                                                                     |
| 5   | Editing title, start or due updates Jira; title and due update Asana; Asana shows no start date and the server refuses one | Jira: WI-0010, one PUT with exactly those three fields, in Jira's changelog. Asana: title and due live (step 3), due and status (step 7). No start input on an Asana card. Refusal: Apex tests | **Passed** (owner, 9/25): a start date on WI-0015 refused - "Asana does not support start dates, so this item cannot have one." (rolled back) |
| 6   | Edits made in Jira or Asana appear on the internal board without a refresh                                                 | CDC subscription and "Live" shown (owner's screenshot); Jest asserts the debounced refresh                                                                                                     | **Passed** (owner, 9/25): live title updates reach the internal board                                                                         |
| 7   | The public board picks up the same edits within about 30 seconds, logged out                                               | Polling cadence, pause and resume in Jest; live, one request per poll                                                                                                                          | **Passed** (owner, 9/25): live title updates reach the public board                                                                           |
| 8   | Dragging a card to another column changes its status and pushes it; Move to still works                                    | WI-0013 and WI-0015/0017 dragged live, one job each; Move to live in step 7                                                                                                                    | -                                                                                                                                             |
| 9   | The admin record link appears on the internal board and never on the public board                                          | Public: no link or ability on any card, live. Internal: the owner's step 7 screenshot shows "Open record"                                                                                      | -                                                                                                                                             |
| 10  | A narrow portrait window shows one centred column with swipe and arrows; landscape shows all columns                       | Public: headless Chrome at 375px, every column centred exactly, arrows and position line; landscape unchanged. Internal: the owner's step 9 screenshot                                         | -                                                                                                                                             |
| 11  | No date renders a day early                                                                                                | Jest runs in America/Los_Angeles and asserts calendar days; live, WI-0005 reads "Due 2 Oct", as stored                                                                                         | -                                                                                                                                             |
| 12  | WI-0011 no longer shows Pending                                                                                            | Board payload since step 5; record cleared in step 7                                                                                                                                           | -                                                                                                                                             |
| 13  | Zero sa11y violations; Lighthouse accessibility no lower than baseline                                                     | sa11y in every Jest suite, nothing pinned. `audit-public-board.mjs`: zero axe violations in the board across seven states, contrast included                                                   | **Passed** (owner, 9/25): Lighthouse accessibility 100, desktop and mobile                                                                    |

## Keyboard-only walkthrough, internal board

The public board's walkthrough is automated in `scripts/audit-public-board.mjs` (both sizes, every
stop ringed). The internal board needs a signed-in session. With the mouse set aside:

1. Tab from the page into the board: View, then Source, then each card's header in column order.
   Every stop shows a dark 2px outline.
2. Enter on a card header opens it; the card lifts and its stripe widens - not the same as the
   outline on a focused, closed card.
3. Tab through the open card: Retry (on a Failed card only), the Move to buttons, Title, Start
   (Jira only), Due, Save changes, Cancel, Open record. Every stop outlined.
4. Escape anywhere in the open card closes it and puts focus back on its header.
5. Move a card with a Move to button: focus follows the card to its new column.
6. In a portrait window, Tab reaches the two arrows before the cards, and Enter on an arrow moves
   the column.

The owner reported the walkthrough as a whole on 9/25: **works as expected**. The steps were not
reported one by one.

## Lighthouse, after

Same conditions as `baseline.md`: the public board, logged out, incognito, no extensions.

| Run                     | Date | Performance | Accessibility | Best practices | SEO |
| ----------------------- | ---- | ----------- | ------------- | -------------- | --- |
| Baseline, desktop       | 9/23 | 97          | 100           | 100            | 82  |
| Baseline, mobile        | 9/23 | 75          | 100           | 100            | 82  |
| After build 08, desktop | 9/25 | -           | 100           | -              | -   |
| After build 08, mobile  | 9/25 | -           | 100           | -              | -   |

Accessibility held at 100 on both, which is the criterion. The other scores were not reported.

## Commands

```bash
sf apex run test --target-org MyScratchOrg --test-level RunLocalTests --result-format human
npm run test:unit
npm run lint
npm run prettier:verify
curl -s -o /dev/null -w '%{http_code}\n' https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board
node scripts/audit-public-board.mjs
```
