# Build 08 — Board design plan

Step 4. No code: this is the plan steps 5–9 build to, for approval first. Both boards share it.
The internal board renders it inside Lightning Experience; the public board, inside the LWR
site's theme.

## Principles

1. **The source accent is the one bold element.** A 4px stripe down the card's left edge, and the
   source label in the same colour. Nothing else on a card is coloured unless it needs attention.
2. **Everything else stays quiet.** Ink for what a card is called, one grey for everything
   about it. No uppercase, no letter-spacing, no filled chips. Status is already said by the
   column a card sits in.
3. **Colour never works alone.** Every accent sits beside its label, every state beside its word
   — "Pending", "Failed", "Overdue". The label is the identifier; the colour helps you find it
   faster.
4. **The theme decides, the component falls back.** Every neutral, the font and the link colour
   come from the site theme's `--dxp-g-*` hooks, with a fallback that renders correctly in
   Lightning Experience, where those hooks do not exist.
5. **Minimum text size is 12px**, down from the 10–11px some labels use today.

## Colour

Six named values. Ratios are measured against white (the card) and against Surface (the column),
the two backgrounds anything sits on.

| Name     | Value     | From                                              | Use                           | On white | On surface |
| -------- | --------- | ------------------------------------------------- | ----------------------------- | -------- | ---------- |
| Ink      | `#1a1b1e` | `--dxp-g-root-contrast` (theme text colour)       | Titles, body text, focus ring | 17.2:1   | 15.9:1     |
| Quiet    | `#636466` | Ink 68% over the page, via `color-mix`            | Everything about a card       | 5.9:1    | 5.5:1      |
| Line     | `#dadbdb` | Ink 16% over the page                             | Card and column borders       | —        | —          |
| Surface  | `#f6f6f6` | Ink 4% over the page                              | Column background             | —        | —          |
| Accent 1 | `#4a4fc2` | `accent-1` token, indigo; Jira's record uses it   | Stripe, source label          | 6.6:1    | 6.1:1      |
| Accent 2 | `#a3306c` | `accent-2` token, magenta; Asana's record uses it | Stripe, source label          | 6.6:1    | 6.1:1      |

Both accents clear 4.5:1 where they colour text and 3:1 as a stripe, with room to spare. Line
and Surface are decorative; every control that needs a visible boundary (inputs, selects) uses
the theme's own form border, `--dxp-g-neutral-3`, at 3.7:1.

**Why indigo and magenta.** They were chosen by elimination, and the reasoning is worth keeping:

- Red and amber already mean Failed and Pending, so orange, rust and ochre were out. Rust against
  the Failed red measured a colour difference of 7; ochre against Pending, 2.
- Blue meant focus: the theme's brand blue, `#005fb2`, is the conventional focus ring. Every
  blue, indigo or violet accent landed within a colour difference of 15 of it for at least one
  kind of colour blindness (violet: 0.9). **So the focus ring moves to Ink** — a 2px outline,
  17:1 on white — and blue is free for an accent.
- Teal and magenta, the obvious non-blue pair, collapse for deuteranopes: colour difference 2.3.
  Indigo and magenta stay apart under every simulation (normal 56, deutan 61, protan 42, tritan
  80), and each sits more than 40 away from Failed, Pending and the focus ring.

That indigo reads as Jira's blue and magenta as Asana's coral is a bonus, not the reason. The
client never knows which is which: it receives `accent-1` or `accent-2` as data and paints it.

**Status colours** are not part of the palette. They carry meaning and appear only when needed:

| State   | Text      | Background | Ratio | From                                  |
| ------- | --------- | ---------- | ----- | ------------------------------------- |
| Failed  | `#c23934` | white      | 5.4:1 | `--dxp-g-destructive`                 |
| Overdue | `#c23934` | white      | 5.4:1 | same; internal board only             |
| Pending | `#7a5000` | `#fdf3dc`  | 6.4:1 | component default; the theme has none |

Synced shows nothing. A record with no remote record shows nothing either — that is the WI-0011
canary fix, and it is a rule in the payload rather than a style.

## Type

The theme's family throughout: `var(--dxp-g-root-font-family, inherit)`, which in Lightning
Experience inherits Salesforce Sans. Sizes in rem against the theme's 1rem base.

| Role                          | Size      | Weight | Notes                                                     |
| ----------------------------- | --------- | ------ | --------------------------------------------------------- |
| Board title                   | 1.25rem   | 600    | The theme's heading size; heavier than its 300 for a tool |
| Public subtitle               | 0.875rem  | 400    | Quiet. Empty by default                                   |
| Column header                 | 0.875rem  | 600    | The status as the data spells it; count in Quiet          |
| Card title                    | 0.9375rem | 600    | Two lines, then an ellipsis; in full when expanded        |
| Card meta (label, IDs, dates) | 0.75rem   | 400    | Tabular numerals. Source label 600, in its accent         |
| Chips (type, sync)            | 0.75rem   | 500    | Sentence case                                             |
| Help, errors, form labels     | 0.8125rem | 400    | Errors in `--dxp-g-destructive`                           |

Line height 1.35 for titles and 1.5 for everything else. Spacing on a 4px grid: 4, 8, 12, 16, 24.

Dates: `12 Sep`, with the year added only when it is not the current one, and in full in the
expanded card. Start and due are built from the `YYYY-MM-DD` string's own parts and formatted in
UTC, never through `new Date('YYYY-MM-DD')`. Created is a real instant and shows in the viewer's
own date.

## The current look, element by element

| Element                                   | Now                                   | Decision  | Why                                                                                                                                                                                                                                                                |
| ----------------------------------------- | ------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Column headers                            | 0.74rem, uppercase, 0.08em tracking   | Change    | Uppercase at 12px strips the word shapes that make text quick to read, and the tracking adds width a narrow column cannot spare. The headers are also the words on the Move to buttons ("Move to In Progress"), so they should look the same in both places.       |
| ID line: `WI-0003 · DOPP-17`              | Middle dot between the two            | Keep      | Compact, and it reads as one identity rather than two facts. Two refinements: the dot becomes a decorative separator hidden from screen readers, which otherwise announce "middle dot" or "dot"; and it shows once when there is no distinct external key (Asana). |
| Type chip                                 | 0.66rem, uppercase, grey fill         | Change    | Sentence case at 12px, outlined, no fill. A filled uppercase tag was the loudest thing on a card; after this it is the source accent.                                                                                                                              |
| Sync chip                                 | 0.64rem, uppercase, amber or red fill | Change    | Same size and case as the type chip. Pending keeps its pale amber so it is findable in a column; Failed becomes a red outline, so the one state that needs action is the one with the strongest edge.                                                              |
| Project tag (`PHQ`, `LEARN`)              | Uppercase, on every card              | Move      | Into the expanded card. The source label now answers "where is this from", and two small uppercase tags compete with it.                                                                                                                                           |
| Epic progress bar                         | Steel blue `#5a7fa8`                  | Change    | Quiet on Line. A second colour on a card would dilute the accent.                                                                                                                                                                                                  |
| Epic Done chip                            | Green                                 | Change    | Quiet like the others. The column already says Done.                                                                                                                                                                                                               |
| Card border and corners                   | 1px, 4px radius                       | Keep, 6px | Unchanged in weight; slightly softer corners. No shadow when collapsed; a small one when expanded.                                                                                                                                                                 |
| Top-of-page detail panel                  | Internal board                        | Remove    | Already decided: cards expand in place.                                                                                                                                                                                                                            |
| "No description synced", "Updated 12 Sep" | Every card                            | Remove    | Already decided.                                                                                                                                                                                                                                                   |

## Wireframes

`▌` is the accent stripe. `‹ ›` are buttons. `[ ]` are form controls.

### Collapsed card — both boards

```
┌──────────────────────────────────────────────────────────┐
▌ Render work items on the board              Pending   ▾  │  ← the header: one button
▌ Jira  WI-0003 · DOPP-17   Story                          │  ← drag surface starts here
▌ Created 12 Sep · Start 24 Sep · Due 1 Oct · Overdue      │     (Overdue: internal only)
└──────────────────────────────────────────────────────────┘
```

The header is the disclosure button: title, sync chip and chevron. Its accessible name is the
title and the chip, and it carries `aria-expanded` and `aria-controls`. The two lines below it are
**where a drag starts** — step 8 must never start a drag from a button, and the header is one. On
a fine pointer in landscape, those lines take `cursor: grab` and show a grip glyph `⠿` at the
left on hover. So a click on the title expands, a press-and-move on the meta lines drags, and
nothing else on a collapsed card is interactive.

An Asana card: `▌ Asana  WI-0015   Book` — one identifier, no start date, ever.

### Expanded card — internal board

```
┌──────────────────────────────────────────────────────────┐
▌ Render work items on the board              Pending   ▴  │
▌ Jira  WI-0003 · DOPP-17   Story                          │
▌ Created 12 Sep 2026 · Start 24 Sep 2026 · Due 1 Oct 2026 │
▌ ──────────────────────────────────────────────────────── │
▌ Board cards grouped by status.              (description, │
▌                                              when present) │
▌ Part of  WI-0002 Public delivery board                   │
▌ Project  PHQ                                              │
▌ Sync     Pending: the Jira update is running.            │
▌          Failed: Jira will not move this issue to Done   │
▌          from where it is. Available: In Progress.       │
▌                                                          │
▌ Move to  ‹To Do›  ‹Done›                                 │
▌                                                          │
▌ Title    [Render work items on the board              ]  │
▌ Start    [2026-09-24]        Due  [2026-10-01]           │
▌          The start date is after the due date.           │  ← inline, beside its field
▌          Move one of them.                               │
▌ ‹Save changes›  ‹Cancel›                  Open record ↗  │  ← admin only
└──────────────────────────────────────────────────────────┘
```

Native `<input type="date">` for both dates. For a source without start dates, the Start input is
absent and a line of Quiet text says why: "Asana items have no start date." The Sync line takes the
source's name from its label. Errors sit under the field they are about; a save that fails as a
whole says so above the buttons.

### Expanded card — public board

```
┌──────────────────────────────────────────────────────────┐
▌ Render work items on the board              Pending   ▴  │
▌ Jira  WI-0003 · DOPP-17   Story                          │
▌ Created 12 Sep 2026 · Start 24 Sep 2026 · Due 1 Oct 2026 │
▌ ──────────────────────────────────────────────────────── │
▌ Part of  WI-0002                                         │
▌ Project  PHQ                                             │
└──────────────────────────────────────────────────────────┘
```

Only what the payload already carries: the full title, full dates, parent number, project label.
No description, no controls. An expanded epic adds its progress: "3 of 4 done".

### Toolbar

```
Internal
All work items                                    21 items · Live
View  [Tasks       ▾]    Source  [All sources ▾]

Public
Portfolio HQ                                             10 items
A subtitle set in Experience Builder, empty by default
Updated 23 Sep · Checked 12:40   ‹Refresh›
View  [Tasks       ▾]    Source  [All sources ▾]
```

Two native `<select>` elements with visible labels. Source options come from the labels in the
data. "Live" on the internal board says the change subscription is connected. On the public board,
after five idle minutes, "Checked 12:40" becomes "Paused" and the Refresh button remains.

### Portrait — `(orientation: portrait) and (max-width: 700px)`

```
┌───────────────────────────────┐
│ Portfolio HQ         10 items │
│ View [Tasks ▾] Source [All ▾] │
│      In Progress · 2 of 3     │  ← position indicator, polite live region
│ ◯‹ ┌─────────────────────┐ ›◯ │
│    │ In Progress       4 │    │
│    │ ▌ card               │    │  ← one column, centred, native swipe
│    │ ▌ card               │    │     (scroll-snap)
│    └─────────────────────┘    │
└───────────────────────────────┘
```

The arrows are 44px circles: white at 85% over the content, a Line border, and an Ink chevron. The
icon measures 12.7:1 against the circle over the darkest thing that can pass beneath it (Ink text),
and 17:1 over a white card. Their accessible names include the destination, "Show To Do column"
and "Show Done column", and each is hidden at its end. Opens on In Progress. With
`prefers-reduced-motion`, an arrow jumps instead of scrolling smoothly.

## Focus and selection

- **Focus:** a 2px Ink outline with a 2px offset, on every interactive element, using
  `:focus-visible`. 17:1 on white and 15.9:1 on Surface.
- **Expanded:** the card lifts, with a small shadow and an Ink-tinted border, and its stripe
  widens from 4px to 6px. So a focused collapsed card and an unfocused expanded one never look
  alike.

## Styling hooks: one shared CSS module

A CSS-only module, `c/boardTheme`, holds every token. Each board component's stylesheet begins
with `@import 'c/boardTheme';`, so there is one place to change and nothing to keep in step.

```css
:host {
  --board-ink: var(--dxp-g-root-contrast, #1a1b1e);
  --board-paper: var(--dxp-g-root, #ffffff);
  --board-quiet: #636466; /* before color-mix, for any browser without it */
  --board-quiet: color-mix(in srgb, var(--board-ink) 68%, var(--board-paper));
  --board-line: color-mix(in srgb, var(--board-ink) 16%, var(--board-paper));
  --board-surface: color-mix(in srgb, var(--board-ink) 4%, var(--board-paper));
  --board-danger: var(--dxp-g-destructive, #c23934);
  --board-link: var(--dxp-g-brand, #005fb2);
  --board-field-border: var(--dxp-g-neutral-3, #858585);
  --board-font: var(--dxp-g-root-font-family, inherit);
  --board-accent-1: var(--phq-accent-1, #4a4fc2);
  --board-accent-2: var(--phq-accent-2, #a3306c);
}
```

A card sets `data-accent={card.accentToken}`, and the module maps the token:
`[data-accent='accent-1'] { --card-accent: var(--board-accent-1); }`. Anything else, including a
missing token, falls to `--card-accent: var(--board-line)`, which is neutral.

**What restyling means.**

- **Theme panel:** text, background, destructive and link colours, and the font. These follow
  the Experience Builder Theme panel with no component change, because every neutral is derived
  from the theme's own text and background.
- **Site CSS:** the accents are the one thing the theme cannot express. They are overridden by
  setting `--phq-accent-1` and `--phq-accent-2` in the site's CSS. That file is committed under
  `digitalExperiences/`, and it is still not a component change.
- **The `--phq-` indirection is deliberate.** A variable re-declared on each component's `:host`
  would beat a value set on the page, so the page can only set a name the component reads rather
  than one it declares.
- **Lightning Experience:** none of the `--dxp-g-*` hooks exist there, and every fallback above
  is the value the internal board renders.

Hook names to confirm against the rendered site in step 6: `--dxp-g-destructive` and
`--dxp-g-neutral-3`. The branding set defines the colours; which hook name carries which one is
read from the live page's computed styles, not assumed.

## Decisions to approve

1. Indigo `#4a4fc2` and magenta `#a3306c` as `accent-1` and `accent-2`, and the focus ring moving
   from brand blue to Ink to free blue for an accent.
2. The type scale, and a 12px minimum.
3. Plain column headers; the middle-dot ID line kept, with its separators hidden from screen
   readers; outlined sentence-case chips; the project tag moved into the expanded card; epic
   progress and Done in Quiet.
4. The drag surface: the meta lines of a collapsed card, with a grip on hover, never its header
   button.
5. One CSS module, `c/boardTheme`; neutrals derived from the theme; accents overridable through
   `--phq-accent-*` in the site's CSS.
