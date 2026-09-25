# ADR — Build 09: priority and sorting

Decisions taken for build 09, with the reasoning that would otherwise be lost. Decisions 1-9 were
made by the owner before the build started and are recorded here at step 0. Narrative lives in
`docs/build-09/summary.md`; org state and traps live in `docs/handoff.md`.

---

## The values, as read from the live systems on 2026-09-25

Read at step 0 through the org's own named credentials (`Jira_Classic`, `Asana_Personal`), so
they are what the adapters will see. `scripts/apex/check-priority-sources.apex` repeats the reads.

| `Priority__c` | Jira priority id (name)                    | Asana `Priority` option gid (name) |
| ------------- | ------------------------------------------ | ---------------------------------- |
| High          | `2` (High)                                 | `1218523733859551` (High)          |
| Medium        | `3` (Medium)                               | `1218523733859552` (Medium)        |
| Low           | `4` (Low)                                  | `1218523733859553` (Low)           |
| _blank_       | `10000` (`–`, U+2013, the project default) | no option (`enum_value: null`)     |

- **Jira.** `GET /rest/api/3/priority` and DOPP's priority scheme (`Default priority scheme`, id
  `10124`, `defaultPriorityId: 10000`). The scheme holds exactly High, Medium, Low and `–`, in
  that order. Highest (`1`) and Lowest (`5`) are gone from the scheme but **still exist
  site-wide**; this scheme is also the default for every new or unassigned project, so an issue
  could only carry one of them by arriving from a project on another scheme - decision 4 covers
  that. All 21 DOPP issues are Medium today.
- **Asana.** The `Priority` custom field is gid `1218523733859550` (enum), attached to the synced
  project `1218523643929429` "Reading and learning tracker" through custom field setting
  `1218523733859557`. The project lives in workspace `1218524467731227` "My workspace".

**Two values in the build prompt were wrong, and the live reads win.** Low is id `4`, not `2`
(the prompt gave `2` for both High and Low). `1218524467731227` is the **workspace**; the synced
project is `1218523643929429`, which is also what `Project__c.External_Project_Key__c` holds.

---

## 1. No priority is a blank `Priority__c`

**Decision.** Salesforce stores no sentinel. Jira's `–` (id `10000`) maps to blank and blank
pushes as `10000`; Asana's empty field maps to blank and blank pushes as `null`.

**Why.** Jira cannot leave an issue without a priority - the scheme default fills it - so `–` is a
stand-in the owner created for exactly this (its own description in Jira: "Stand-in for blank or
null priority to map to Asana"). Storing it would put one vendor's workaround into the neutral
model, and Asana would then need a value it has no way to hold. Blank is the natural "none" on
both boards: no badge, "No priority" in the editor.

**Consequence.** `–` is the only Jira id whose mapping is blank, so the mapping has to be able to
say "blank" as an answer, distinct from "no mapping" (decision 4). Step 1 found it could not:
`Normalized_Value__c` was required, and the loader already treated an empty one as a half-filled
row that maps nothing - a guard with its own test. So `Field_Mapping__mdt` gained **Maps To
Blank**, a checkbox: a row maps to blank only when it says so, with an empty normalized value. An
empty value without the box is still a half-filled row, and a row with both is a contradiction;
each maps nothing. `Normalized_Value__c` is no longer required, for that row alone.
`FieldMappingService.normalizedFor` still answers null for both blank and unknown, as it always
has; the new `isMapped` is the question that tells them apart. Outbound, a blank looks up the
blank row - Jira `10000` - and a source with none answers null, which the Asana adapter sends as
an empty field. The Asana `Priority` field's own gid is a `Field` row, as Jira's start-date field
id is.

---

## 2. Map by id, never by name

**Decision.** Jira priority ids and the Asana field and option gids live in `Field_Mapping__mdt`.
No priority name appears in Apex logic or LWC.

**Why.** The same rule as build 07's section gids (ADR build-07, decision 4): an id survives a
rename and a name does not. Here it matters twice over - one of the names is an en dash, which
differs from a hyphen in no way anyone can see in an editor or a log, and a match on it would
break silently on the day somebody retypes it. Jira ids are per site, so they are configuration,
like the start-date field id build 08 put in a `Field` row.

---

## 3. Three values, restricted picklist, no default, not required

**Decision.** `Priority__c` is restricted to High, Medium and Low, in that order. No default; not
required.

**Why.** A default would give every record created by hand a priority its source never had, and
the first save would push it. Not required, because "none" is a legitimate state in both sources.
Restricted, because an unrestricted picklist would let an inbound value nobody mapped become a
fourth priority by accident - the opposite of decision 4.

---

## 4. An unknown inbound priority changes nothing and is logged

**Decision.** An inbound priority id with no mapping leaves `Priority__c` unchanged, writes a
warning naming the id to the callout log, and applies the rest of the change. It never clears the
field and never fails the delivery.

**Why.** Both tools are owned and used by one person, so a new priority is a deliberate act, and
this is a guard rather than a feature. Clearing the field would read as "the owner removed the
priority", which is false; failing the delivery would lose a status or title change carried
beside it. Supporting a real new value is a future build: a picklist value and a mapping row.

---

## 5. Sorting happens in the browser

**Decision.** Sort is client-side on both boards. No Apex request, no new query, no parameter.

**Why.** Both payloads already carry every card the board can show. A server-side sort would need
a parameter on `PublicBoardController`, whose single parameterless method is what keeps the public
board read-only by construction, and a query per choice, against the one-query budget a Developer
Edition site depends on.

---

## 6. Default sort is Due date; Priority is the alternative

**Decision.**

- **Due date** (the default): earliest first, no date last; ties by priority, then key.
- **Priority**: High, Medium, Low, then none; ties by due date, then key.

**Why.** Due date answers "what is next", which is what a visitor opens a board to learn. Each
order ends on the key so that it is total: two cards with equal dates and priorities keep their
places across polls and live refreshes instead of trading them on every re-render. Dates compare
as `YYYY-MM-DD` strings, never as `Date` objects (ADR build-08, decision 7).

**Consequence.** Both payloads carry `priorityRank` (1, 2, 3 or null) beside the label, so the
order lives in one place in Apex and the client sorts a number without knowing a name.

---

## 7. In the Epics view, epics keep their order

**Decision.** Only the items inside each epic sort. The epics themselves stay where they are.

**Why.** Epics do not have a priority of their own on the board - `EpicRollup` does not roll one
up - and an epic's due date says little about the work inside it. Reordering the epics on a sort
change would move the page's landmarks under the visitor for no gain.

---

## 8. The sort choice is not remembered

**Decision.** Every visit opens on Due date. Remembered filters and sort, and a Priority filter,
are version 2.

**Why.** Build 08 did not remember filters either. Remembering one control and not its neighbours
would be inconsistent, and the version 2 work is the same mechanism for all of them.

---

## 9. The badge is neutral text

**Decision.** A card with a priority shows it as neutral text; there is no colour per priority. A
card with no priority shows no badge. The editor's empty option reads "No priority". The badge's
accessible name reads "Priority: High", not a bare word.

**Why.** The one colour on a card is the source accent (ADR build-08, decision 1). A red High
would compete with it, and a colour carries no meaning to a screen reader or on a monochrome
display anyway.

---

## Found at step 0

**Jira accepts a priority on every DOPP issue type, whatever `editmeta` says.** `editmeta` offers
`priority` (operation `set`, values `2`, `3`, `4`, `10000`) on Story only, and step 0's first
report took that to mean Jira would refuse it on Epic, Subtask, Bug and Task - five of the 14 Jira
items in Salesforce - and, since a Jira edit is one `PUT`, take a title or date sent beside it down
too. **That was wrong, and a write proved it.** A real change - Medium to High and straight back,
with `notifyUsers=false` - returned 204 and landed on DOPP-21 (Task), DOPP-1 (Epic), DOPP-12
(Subtask) and DOPP-20 (Bug). All eight deliveries reached Salesforce and processed; the four
records stayed Synced with nothing pending, and nothing was pushed back. DOPP is a
**team-managed** project (`style: next-gen`): there are no screens, and in this project
`editmeta` describes the issue type's layout, not what the API will take. A same-value write had
answered 204 first, but proved nothing - `updated` did not move, so Jira may never have validated
it. `overrideScreenSecurity=true` answers 403 for an API token (Connect and Forge apps only).

**Consequences.** No Jira setup is needed for build 09. No per-type rule exists anywhere in
Salesforce, and none is added: priority rides the build 08 push unchanged, which already sends
only the fields a save changed (`Pending_Push_Fields__c`), so a title edit never carries a
priority and a priority edit carries nothing else. If Jira ever does refuse one - a type whose
behaviour changes, a project on another scheme - the existing refusal path applies: the field
stays pending, the card shows Failed with Jira's reason, and Retry or a new edit sends it again.
`editmeta` is not a reliable test in this project, so `check-priority-sources.apex` no longer
reads it.

**The Asana webhook's filters could not be read with the org's token.** `GET /webhooks` answers
an empty list for `Asana_Personal`'s token: Asana lists only webhooks registered by the token that
asks, and this one was registered from a shell with another. The live test is what the step asks
for, and it passed: a Priority change arrived as a task `changed` event with
`change.field: custom_fields`, carrying the field gid and the option gid, and processed in about
five seconds; clearing it arrived with `enum_value: null`. Build 07's registration sent no filters.
