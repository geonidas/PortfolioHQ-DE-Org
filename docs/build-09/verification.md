# Build 09 — Verification

Started in step 6 with the keyboard walkthrough, which each UI step updates. Step 8 adds the
acceptance criteria, the owner's column and Lighthouse after.

## Keyboard-only walkthrough, internal board

The public board's walkthrough is automated in `scripts/audit-public-board.mjs` (both sizes, every
stop ringed). The internal board needs a signed-in session. With the mouse set aside:

1. Tab from the page into the board: View, then Source, then each card's header in column order.
   Every stop shows a dark 2px outline.
2. Enter on a card header opens it; the card lifts and its stripe widens - not the same as the
   outline on a focused, closed card.
3. Tab through the open card: Retry (on a Failed card only), the Move to buttons, Title, Start
   (Jira only), Due, **Priority** (build 09 step 6; for a source whose `Board_Source__mdt` says it
   holds one - Jira and Asana both do), Save changes, Cancel, Open record. Every stop outlined.
4. In Priority, the arrow keys move between the choices - the board's in priority order, then No
   priority - and the choice is not saved until Save changes.
5. Escape anywhere in the open card closes it and puts focus back on its header.
6. Move a card with a Move to button: focus follows the card to its new column.
7. In a portrait window, Tab reaches the two arrows before the cards, and Enter on an arrow moves
   the column.

The owner reported the walkthrough passed on 9/26, with the step 6 editor in place.

Jest holds the open card's order - Title, Start, Due, Priority, Save changes, Cancel - in
`boardCard.test.js`, "sits between the dates and Save".
