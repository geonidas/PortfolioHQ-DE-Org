# ADR — Build 08: board redesign, in-card editing, live updates

Decisions taken during build 08, with the reasoning that would otherwise be lost. Narrative lives
in `docs/build-summaries/build-08.md`; org state and traps live in `docs/handoff.md`. The design
decisions themselves - palette, type, wireframes - are in `docs/build-08/design-plan.md`.

---

## 1. The public board names the vendor

**Context.** Build 08 puts a source label on every card - "Jira", "Asana" - with a colour accent
per source, and gives both boards a filter by source. The public board is read by anonymous
visitors.

**What this reverses.** Build 07, decision 6: "no vendor name reaches an anonymous visitor at all,
which is strictly better than sending one." The public card carried `condensesIntoEpic`, a boolean,
precisely so the client could act on the source without learning which it was.

**Decision.** Publish the label. `PublicCard` and `PublicEpic` carry `sourceLabel` and
`accentToken`, answered by `BoardSourceRules` from `Board_Source__mdt`. The half of build 07's rule
that mattered is kept, and is now enforced rather than merely followed: **the client never branches
on a vendor.** It renders the label and paints the token; it never compares either.
`lwc/__tests__/vendorNeutrality.test.js` fails on any vendor name in LWC source outside a comment.

**Why the reversal is sound.**

- **The portfolio's point is the integrations.** A public board that hides which systems it
  integrates hides the thing it exists to show.
- **Nothing is disclosed that was secret.** The label is display text chosen in custom metadata, not
  a system identifier. The public page already showed Jira-shaped keys (`DOPP-16`).
- **The capability behind the old rule stays intact.** Adding a source is still a metadata record
  and an adapter; no component learns its name. The label and token are data, like the title.

**Enforcement, so this stays a deliberate act.**

- `PublicBoardControllerTest` asserts both DTO key sets exactly, and failed first on this step,
  naming `sourceLabel` and `accentToken` (and the three date fields beside them).
- `GuestAccessTest` now asserts the guest permission set's readable fields exactly - it previously
  only forbade four - and failed first, naming the three new field grants.
- Neither test was updated until it had failed on the change.

**Consequences.** The accent colour is a token name on the wire (`accent-1`), mapped to a colour by
the shared stylesheet; an unknown token renders neutral. Changing what a source is called or how it
looks is a metadata or stylesheet change. `condensesIntoEpic` stays a boolean: it is a behaviour, and
behaviours stay answered rather than inferred.

**Revisit when** a source is added whose name should not appear publicly - its `Board_Source__mdt`
label can say something generic without any code change.

---

## 2. One card for both boards, with abilities granted by the board

**Context.** Until step 6 there were three card components: `workItemCard` for the internal board
and `publicWorkItemCard` and `publicEpicCard` for the public one. The split existed for a real
reason - the internal card was clickable, and a clickable card in front of an anonymous visitor
advertises an action that does not exist - but it meant every card change was made twice, and the
two had already drifted: different sizes, different fallbacks, a sync flag on one and not the
other's epics.

**Decision.** One `boardCard` and one `boardEpicCard`, used by both boards. What a card can do is
passed in by the board, not inferred by the card: `selectable` puts a button in the card's heading,
the internal board passes it and the public board does not. A public card therefore contains no
control at all, by construction rather than by a branch. Step 7 adds the rest of the abilities -
expand, edit, drag - the same way, so each is something the internal board grants and the public
board never does. The shared view model lives in `boardModel`, pure functions beside
`boardLayout`, and the shared tokens in `boardTheme`, a CSS-only module.

**What makes sharing safe.** An LWC import is not conditional: anything a shared module imports
ships to the guest. `lwc/__tests__/guestBundle.test.js` walks the public board's graph from source
(JavaScript imports, the child components its templates render, the stylesheets they import) and
fails if:

- any Apex import appears in it other than `PublicBoardController.getPublicBoardData`, made by the
  public board itself;
- `WorkItemBoardController` is named anywhere in it;
- anything in it imports `lightning/empApi`;
- any module the two boards share imports from `@salesforce/*` or `lightning/*` at all.

It was run against a deliberately planted `WorkItemBoardController` import in `boardCard` and
failed on three of its five rules before being trusted.

**The guard test widened too.** The public board's "no control but these" test used to query the
board's own shadow root, so a button added inside a card - which renders in its own shadow tree -
would have passed it. It now walks every shadow root and asserts the exact list: Refresh, View,
Source. (As written in step 6 it compared with `toEqual`, which skips `undefined` entries, so a
control with no identifying attribute still slipped past it. Step 7 found that and made it
`toStrictEqual`; see below.)

**Consequences.** A card change is made once. The internal board's step 1 accessibility pin,
`aria-allowed-role` for `<article role="button">`, is gone: the matcher failed on the fix as it was
built to, and both boards now pass sa11y with nothing pinned. The epic title truncation carried
since build 06 is fixed because there is one epic card to fix.

**Revisit when** a board needs a card that differs in more than its abilities. Until then, a
difference between the boards is a capability, not a component.

**Amended in step 7.** Two things step 6 said here were wrong or are superseded.

- **Opening a card is not an ability.** Step 6 listed "expand" among the abilities the internal
  board would grant. The spec gives the public board an open card too - read only, showing what
  the payload already carries - so the disclosure is on every card on both boards, and the board
  says which card is open through `expandedKey`. What opening _shows_ is still the board's to
  grant: `abilities` is `{ moveTo, edit, openRecord, titleMax }`, the internal board passes it, and
  the public board passes nothing. A public open card holds its full title, dates with years, the
  public parent's number and the project, and one control: its disclosure. `selectable` is gone;
  the disclosure replaced it.
- **The guard's exact list was not exact.** It mapped each control to its `data-filter` or
  `data-action` and compared with `toEqual`, which ignores `undefined` array entries - so every
  control without one of those attributes vanished from the comparison. Step 7's disclosure buttons
  passed it untouched, which is how it was found. It now names every control (an unknown one by its
  tag) and compares with `toStrictEqual`; the expected list is Refresh, View, Source, and one
  disclosure per card. It was proven by planting a link in the card: both guards failed.

The card still calls no Apex. It raises `toggle`, `move`, `save` and `openrecord`; the internal
board calls `changeStatus` and `saveDetails`, generates the record URL with `NavigationMixin`, and
hands the outcome back as `feedback`. `lightning/navigation` is imported by the internal board
alone, so the guest-bundle rule that shared modules import nothing from `lightning/*` still holds.

---

## 3. A drop is Move to by another route, and Retry is a save

**Context.** Step 8 adds drag-and-drop on the internal board and a Retry for a push the source
refused. Both are new ways to cause a push, and the outbound path already has one rule that must
not bend: pushes are queued by `WorkItemTrigger` and nothing else.

**Decision - drag.** A drop calls the same `changeStatus` the Move to buttons call, through the
same board method. No optimistic move: the card stays in its column, dimmed, until Salesforce has
committed, and the refresh puts it in the new one. A failed save therefore needs no snap-back
animation - the card never left - and the board says what happened in a status line under the
toolbar, because a closed card has nowhere to show a message. Drag is an ability the internal
board grants only while the pointer is fine and the layout is not portrait, re-evaluated when
either changes; the Move to buttons stay for everyone else (WCAG 2.2, 2.5.7). The drag starts from
the card's left edge - the accent stripe and its gutter, the card's full height - or from its
detail lines, and never from its header, which is a button, or from an open card, which holds
inputs. The edge was added at the user's request after the first live try: the stripe is where a
hand goes. On the internal board every column is as tall as the tallest, so a column is a drop
target however far down the board has been scrolled. Only the dragged record moves: its children keep their own status.

**Decision - Retry.** Retry is a save that moves `Sync_Status__c` from Failed to Pending, which
the trigger reads as a request to push what is still waiting. `retryPush` makes that save and
nothing else. So the rule lives in the trigger, where every client meets it - the record page, an
API call and a data load retry the same way the board does - and the invariant that no controller
calls the sync service holds.

**Consequences.** Setting Pending by hand on a Failed record now sends it again; the handoff says
so. A transient failure is still not retried automatically - someone presses Retry or saves a
change - which keeps the number of pushes a record can cause bounded by what people do.

**Revisit when** transient failures are common enough that waiting for a person is the problem.
A scheduled retry would be the same save, made by a job instead of a button.

---

## 4. One layout for both boards, with the boards' own columns slotted into it

**Context.** Step 9 gives both boards a portrait layout: one column at a time, snap and swipe, two
arrows named for the column they show, a position line, opening on In Progress. The two boards
render different columns - the internal ones are drop targets holding cards with abilities, the
public ones hold inert cards - and until now each laid its columns out with its own grid.

**Decision.** A shared `boardColumns` component owns the layout: the track, the arrows, the
position line and the media queries. Each board still renders its own columns, marked
`data-board-column`, into its slot, so the cards, the drop handlers and the abilities stay where
they were and nothing about them is passed through. In landscape the track is the grid it always
was; in portrait it scrolls horizontally with snap points. The internal board's full-height
columns (step 8) are a CSS variable it sets, not a second layout.

The portrait condition is written once in `boardLayout.PORTRAIT_QUERY` and repeated in two
stylesheets, because CSS cannot import it. `lwc/__tests__/portraitQuery.test.js` fails if either
drifts; it was run against a stylesheet changed to 720px and did.

The arrows sit on a zero-height rail that sticks at mid-screen, not at the top of the column as
the step 4 wireframe drew them: a portrait column can be long, and an arrow at its top is out of
reach once the visitor has scrolled down it.

**Consequences.** Portrait behaves identically on both boards because it is one component. Drag
is off in portrait (step 8), so the arrows and a swipe are the only ways between columns there,
and Move to still moves a card. `boardColumns` imports nothing but `boardLayout`'s constants, and
the guest bundle test lists it among the shared modules.
