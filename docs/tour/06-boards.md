# Two boards, one set of parts

Both boards are Lightning Web Components. The internal board reads, edits, drags, retries and
features; the public board reads. They share one card, one toolbar, one layout and one view model,
without the public bundle ever carrying the internal board's Apex.

Concepts: LWC modules and bundles, `@wire` and `refreshApex`, Change Data Capture and
`lightning/empApi`, LWR sites, Jest with jsdom and accessibility checks.

<!-- stops:start -->

1. [Why can the two boards share modules at all?](#1-why-can-the-two-boards-share-modules-at-all)
2. [How is the public bundle kept free of the internal board's Apex?](#2-how-is-the-public-bundle-kept-free-of-the-internal-boards-apex)
3. [Why does the card decide nothing?](#3-why-does-the-card-decide-nothing)
4. [Why does the client never name a vendor?](#4-why-does-the-client-never-name-a-vendor)
5. [Why are dates sent as strings?](#5-why-are-dates-sent-as-strings)
6. [Why does Jest run in Los Angeles?](#6-why-does-jest-run-in-los-angeles)
7. [How does the internal board stay live?](#7-how-does-the-internal-board-stay-live)
8. [Why does the public board poll, and why does it stop?](#8-why-does-the-public-board-poll-and-why-does-it-stop)
9. [Why does the spoken text come from data?](#9-why-does-the-spoken-text-come-from-data)

<!-- stops:end -->

## 1. Why can the two boards share modules at all?

<!-- at: force-app/main/default/lwc/boardLayout/boardLayout.js | This module imports no Apex, and that is the whole reason it can be shared. -->

[boardLayout.js:4](../../force-app/main/default/lwc/boardLayout/boardLayout.js#L4)

An LWC import is not conditional: whatever a module imports ships in the bundle of every page that
uses it. A component that imported `WorkItemBoardController` would carry the class a guest must
never reach into the public page, whichever branch ran. So the two boards stay separate
components, each importing its own controller, and everything they share imports no Apex -
`boardLayout`, `boardModel`, `boardCard`, `boardEpicCard`, `boardColumns`, `boardToolbar`,
`boardTheme`. The shared modules are pure: plain data in, plain data out, no wire, no state.

Nothing the controller returns is dropped on the way: a card whose status is not a configured
column comes back in `other` and is shown below the board, not lost.

**Concept.** An LWC bundle's static imports are resolved at build time and shipped with it, Apex
method imports included.

**Pattern: Safe by construction.** The public bundle cannot call a class it does not contain.

## 2. How is the public bundle kept free of the internal board's Apex?

<!-- at: force-app/main/default/lwc/__tests__/guestBundle.test.js | An LWC import is not conditional -->

[guestBundle.test.js:4](../../force-app/main/default/lwc/__tests__/guestBundle.test.js#L4)

A unit test walks the public board's graph from source - JavaScript imports, child components
named in templates, CSS imports - and asserts that the only Apex import anywhere in it is
`PublicBoardController.getPublicBoardData`, that nothing in it imports `lightning/empApi` (which
LWR sites do not support), and that every module shared with the internal board imports nothing
from `@salesforce` or `lightning` at all.

It reads source rather than a build, so it runs in the ordinary Jest suite and fails before a
deploy rather than on a public page.

**Pattern: Pin the contract exactly.** "The guest bundle reaches one Apex method" is asserted as a
fact about the whole graph, not trusted to review.

## 3. Why does the card decide nothing?

<!-- at: force-app/main/default/lwc/boardCard/boardCard.js | @api abilities; -->

[boardCard.js:34](../../force-app/main/default/lwc/boardCard/boardCard.js#L34)

One card serves both boards. It renders the view model the board hands it and raises events -
toggle, move, save, open record - and the board does the work and hands the outcome back. What an
open card can do is passed in as `abilities`: the statuses it can move to, whether it can edit,
retry, drag or open the record. The internal board passes them; the public board passes nothing, so
a public card has exactly one control, its disclosure. The card calls no Apex, which is what lets
both boards share it.

**Failure mode.** A card that imported the save method, and hid its controls on the public board,
would put the write back into the guest bundle.

**Pattern: Safe by construction.** A control the public board never grants is absent from the
public card, not hidden on it.

## 4. Why does the client never name a vendor?

<!-- at: force-app/main/default/classes/BoardSourceRules.cls | The board's counterpart to WorkItemAdapterFactory -->

[BoardSourceRules.cls:4](../../force-app/main/default/classes/BoardSourceRules.cls#L4)

`BoardSourceRules` is the only reader of `Board_Source__mdt`. The controllers ask it about each
card's source and send the answers - a label to show, an accent token such as `accent-1` that the
stylesheet maps to a colour, whether the source supports start dates and priority, whether its work
condenses into epics - so no component branches on which vendor a card came from. A client may show
a label; it never compares one.

A unit test (`vendorNeutrality.test.js`) fails on "jira" or "asana" anywhere in LWC JavaScript,
HTML or CSS outside comments. It strips comments with a real tokenizer, because a regular expression
that strips `// ...` also strips half of `https://...`.

**Pattern: Send answers, not inputs.** The client receives decisions it can render, and a third
source needs a metadata row, not a component change.

**Pattern: Configuration, not code.** Per-source behaviour is a row in custom metadata, read with
`getAll()`, which costs the public board no query.

## 5. Why are dates sent as strings?

<!-- at: force-app/main/default/lwc/boardModel/boardModel.js | export function formatDay( -->

[boardModel.js:77](../../force-app/main/default/lwc/boardModel/boardModel.js#L77)

A start or due date is a calendar day, not an instant, so it travels from Apex as a `YYYY-MM-DD`
string and the client reads the day from the string's own parts. The creation date is a real
instant, so it arrives as a Datetime and shows in the viewer's own zone. On the Apex side, `IsoDate`
reads a vendor's day into a `Date`, never a `Datetime`.

**Failure mode.** `new Date("2026-09-24")` is midnight UTC, which is the 23rd for every visitor west
of Greenwich: every due date on the board one day early, for exactly the people most likely to use
it.

**Pattern: A day is not an instant.** A value without a time zone never passes through a type that
has one.

## 6. Why does Jest run in Los Angeles?

<!-- at: jest.config.js | process.env.TZ = "America/Los_Angeles"; -->

[jest.config.js:7](../../jest.config.js#L7)

Every Jest run is pinned to a zone behind UTC, so a date bug fails locally rather than only for
visitors in the Americas. The pin is set in the config, before the workers start, because Jest hands
each test file a copy of `process.env` - setting `TZ` inside a test silently does nothing.
`boardModel.test.js` asserts the zone first, so removing the pin fails loudly.

**Pattern: A day is not an instant.** The zone where the bug appears is the zone the tests run in.

**Pattern: Control what the test reads.** The machine's own time zone is an input, so the suite fixes
it rather than inheriting it.

## 7. How does the internal board stay live?

<!-- at: force-app/main/default/lwc/workItemBoard/workItemBoard.js | subscribe(CHANGE_CHANNEL, -1, () => this.scheduleRefresh()) -->

[workItemBoard.js:120](../../force-app/main/default/lwc/workItemBoard/workItemBoard.js#L120)

It subscribes to Change Data Capture on `Work_Item__c` and refreshes when a change arrives,
debounced by a second and a half, because one save produces several events: the edit, then the
sync's own write-back a moment later. The header says Live only once the subscription has resolved,
and stops saying it when the stream reports an error. The subscription belongs to the container
alone; the shared components never import `lightning/empApi`.

CDC ignores sharing, so Salesforce allows the subscription only to a user with View All Records on
the object (or View All Data). The project's permission set deliberately does not grant it, so for
such a user the board loads, refreshes after their own saves, and simply does not say Live.
Widening the permission would fix that and would also widen what they can see - a decision, not a
fix.

**Concept.** Change Data Capture publishes an event for each record change; `lightning/empApi`
subscribes to it from a component in Lightning Experience.

**Pattern: Honest state.** "Live" is shown only while it is true.

**Pattern: Know who your code runs as.** Whether the board is live depends on the viewing user's
permissions, not on the code.

## 8. Why does the public board poll, and why does it stop?

<!-- at: force-app/main/default/lwc/publicWorkItemBoard/publicWorkItemBoard.js | export const IDLE_MS = 300000; -->

[publicWorkItemBoard.js:42](../../force-app/main/default/lwc/publicWorkItemBoard/publicWorkItemBoard.js#L42)

LWR sites do not support `lightning/empApi`, so the public board re-reads every 30 seconds
instead, but only while the tab is visible and the visitor has done something in the last five
minutes.
After that it shows Paused, and a Refresh button is always there. Each poll is the same
parameterless, one-query call the page loaded with, so polling widens nothing.

The method is `cacheable=true` without a global scope, so it is not cached on the CDN and every
poll reaches the server. That is what makes "every 30 seconds" true, and why the idle cap matters: a
Developer Edition site gets ten minutes of server time a day, and one unattended tab would spend a
real share of it. The view is chosen once, from the first payload, and a later poll never moves
the visitor.

**Pattern: Design to the limit.** The refresh rate is set by what the site's allowance can afford,
and spending stops when nobody is looking.

## 9. Why does the spoken text come from data?

<!-- at: force-app/main/default/lwc/boardCard/boardCard.html | <span class="assistive">{card.metaSpoken}</span> -->

[boardCard.html:57](../../force-app/main/default/lwc/boardCard/boardCard.html#L57)

The LWC template compiler drops the whitespace between tags: `<span>A</span> <span>B</span>`
renders as "AB". A flex gap hides that visually, but a screen reader hears the spans run together
("JiraWI-0003"). So `boardModel` builds a spoken string for each meta line, rendered in a visually
hidden span, and the drawn line, separator dots included, is `aria-hidden`.

Accessibility is checked in two places: sa11y in every Jest test of a component, and axe-core in a
real browser over the public board as a guest (`scripts/audit-public-board.mjs`), which is the only
place colour contrast is measured, since jsdom has no layout.

**Failure mode.** The markup reads correctly in the source and wrongly aloud, and no visual check
notices.

**Pattern: Test the path production takes.** What a visitor hears is the compiled output, so that
is what gets probed and checked.

<!-- nav:start -->

---

[← 5 · The public boundary](05-public-boundary.md) · [All tours](README.md) · [7 · Proving it: tests and operations →](07-proving-it.md)

<!-- nav:end -->
