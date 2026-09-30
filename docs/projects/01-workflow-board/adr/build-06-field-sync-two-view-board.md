# Build 06 — Field Sync and the Two-View Board: Decision Register

Architecture decisions taken while syncing issue type and parent from Jira, and while giving the
public board a second view over the same payload. Recorded so none of it gets re-litigated from
memory.

|               |                                                                   |
| ------------- | ----------------------------------------------------------------- |
| **Build**     | 06 — field sync and the two-view board                            |
| **Branch**    | `feature/first-branch`                                            |
| **Commits**   | `e0fc34c` (step 2), `8b13915` (steps 3–6)                         |
| **Decisions** | 16                                                                |
| **Tests**     | 182 Apex, 55 Jest                                                 |
| **State**     | Live to anonymous visitors, verified against a real Jira delivery |

**Origin labels**

- **From spec** — written into Build 06's requirements.
- **Directed** — a decision the owner made when asked.
- **Proposed** — an implementation choice the spec left open.
- **Departs from spec** — a deliberate deviation, with reasoning recorded.

---

## Inbound field sync

### ADR-001 — No stub records for an unresolved parent

**Origin:** Directed

**Decision.** A parent reference Salesforce has not seen leaves `Parent_Work_Item__c` null, writes
one `Integration_Log__c` row naming both sides, and the delivery still reports `Processed`.

**Context.** The spec contradicted itself: the prose said "do not create stub records", the test list
required a stub, and step 1 asked for a stub approach. Raised as a blocking question rather than
resolved silently. Three options were put: no stubs, stubs, or no stubs plus a
`Parent_External_Id__c` field to make resolution re-runnable. The owner chose no stubs.

A stub would be a titleless, projectless `Work_Item__c` rendering on the internal board as a blank
card. Two of the three stub tests were also near-tautologies — "the stub is not public" holds from
field defaults alone, and "the parent's own delivery fills it rather than duplicating" is free from
upserting on `External_Id__c`.

**Consequences.** Nothing back-fills the link when the parent later arrives; only a subsequent
delivery for the _child_ repairs it. The log row is the only record of the gap. This is a knowingly
accepted cost, not an oversight, and closing it needs the declined field or the reconciliation job.

### ADR-002 — Type and parent are assigned only when the payload carries them

**Origin:** From spec

**Decision.** `Type__c` and `Parent_Work_Item__c` are written only when present in the delivery,
following build 04's rule for `Title__c`.

**Context.** Most deliveries here are status transitions, whose payloads carry no summary, issuetype
or parent at all. Writing a null through would blank known data on every one of them.

**Consequences.** A field cleared in Jira does not clear in Salesforce. Un-parenting an issue does not
propagate.

### ADR-003 — A blank issue type name counts as absent, not unmapped

**Origin:** Proposed — refinement beyond the spec

**Decision.** An `issuetype` object present but carrying no `name` is treated as if the payload had no
issuetype at all, rather than normalising to `Unspecified`.

**Context.** The spec required an _unrecognised_ type to store `Unspecified`. It said nothing about a
malformed one.

**Consequences.** Overwriting a known type with the catch-all on the strength of malformed input is
avoided. An unrecognised but non-blank name still lands on `Unspecified`, as specified.

### ADR-004 — Type normalisation lives in the adapter

**Origin:** Proposed

**Decision.** `normalizeType` added to `IWorkItemAdapter` and implemented in `JiraAdapter` over a
`TYPE_ALIASES` table beside `STATUS_ALIASES`.

**Context.** `fields.issuetype.name` is Jira vocabulary, and the interface's whole contract is that
vendor vocabulary stays inside the implementing class.

**Consequences.** The interface grew, so `WorkItemSyncServiceTest`'s mock had to implement it. Adding
an Asana adapter remains a new class rather than an edit to callers.

### ADR-005 — Jira's `Sub-task` maps to `Task`

**Origin:** Proposed

**Decision.** Sub-task normalises to `Task` rather than to `Unspecified`.

**Context.** `Type__c` is a restricted picklist with no Subtask value, so a subtask has to land
somewhere. Flagged explicitly at the time as a judgement call.

**Consequences.** A real distinction is flattened. Reversible in one line of `TYPE_ALIASES`.

### ADR-006 — Parent resolution is a second pass

**Origin:** From spec

**Decision.** Pass one upserts every work item in the batch; pass two links parents by
`External_Id__c`, over the upsert results plus one query for parents the batch did not carry.

**Context.** A delivery batch can carry a child and its parent in either order. Resolving inline would
miss a parent not yet inserted — intermittently, depending on payload order.

**Consequences.** One extra query and one extra DML on the inbound path. Correctness no longer depends
on the order Jira happens to send things in.

### ADR-007 — A self-referencing parent is refused

**Origin:** Proposed

**Decision.** A payload naming an issue as its own parent leaves the lookup null and logs.

**Context.** Nothing in the schema prevents a self-lookup pointing at its own row, and a cycle of
length one is still a cycle for anything walking ancestors.

**Consequences.** The read-side cycle guard has one less case to absorb, and the data never reaches
that state from this path.

### ADR-008 — Two silent failures now report themselves

**Origin:** From spec (ownership) and ADR-001 (parent)

**Decision.** Both write `Integration_Log__c` with `Direction__c = 'Inbound'`, `Is_Success__c = false`,
and null `Endpoint__c` / `HTTP_Method__c`. Writes are allow-partial and never throw.

**Context.** A record that is public, synced and invisible because no admin resolved to own it is the
failure most likely to waste an hour at launch, and build 05 left it silent.

**Consequences.** First rows anywhere to use `Direction__c = 'Inbound'`. Two new writers against an
object that already has no purge job.

---

## Epic resolution

### ADR-009 — The ancestor walk is iterative and bounded twice

**Origin:** From spec

**Decision.** A visited set catches a cycle of any length, including the length-one self-parent case;
a depth cap of 10 catches a longer chain. Both degrade to "orphan" rather than throwing.

**Context.** `Parent_Work_Item__c` is a self-lookup and nothing prevents a loop. Real Jira hierarchies
run three deep.

**Consequences.** A malformed hierarchy cannot hang or crash the public board. It silently reads as
unparented instead, which is visible on the page rather than in an error.

### ADR-010 — A withheld ancestor breaks the chain

**Origin:** Proposed — flagged before implementation

**Decision.** The walk sees public rows only, so a chain passing through a private ancestor stops
there and the item reads as an orphan.

**Context.** Build 05 established that a child whose parent is withheld simply has no parent. This
applies the same rule upwards. The alternative — querying non-public rows to complete the chain —
would mean the guest-facing query is no longer the single gate.

**Consequences.** An epic's child count can legitimately disagree with Jira. Counts cover public
descendants only; querying the true total would publish the existence of records the visitor cannot
see.

### ADR-011 — A descendant counts towards the epic it resolves to

**Origin:** Proposed

**Decision.** "Total children" means every descendant whose nearest `Epic` ancestor is this epic, not
direct children only. A subtask two hops down counts.

**Context.** The number on the card should equal the number of cards the task view shows beneath it.

**Consequences.** Flagged for the owner as a reading of an ambiguous phrase; not contested.

### ADR-012 — The task-view filter cannot live in the query

**Origin:** Departs from spec

**Decision.** The query text keeps exactly the two public flags it had. Epic and orphan filtering
happens in memory afterwards.

**Context.** The spec asked for the filter to be "hardcoded in the query as before". SOQL cannot
express "nearest `Epic` ancestor is not Done" across arbitrary hops, so the spec's guarantee could not
be delivered as written. Raised before implementation.

**Consequences.** The in-memory pass can only ever **remove** rows from an already-gated set, never
add. The security boundary is unchanged and still lives in one place — but that fact is now a property
of the code's shape rather than of the query text alone.

### ADR-013 — `LastModifiedDate` orders the completed epics

**Origin:** Proposed

**Decision.** Completed epics are capped at three by `LastModifiedDate`, not by
`Remote_Last_Modified__c`.

**Context.** The semantically better field is absent from `Portfolio_HQ_Guest`, and the query runs
`WITH USER_MODE` — reading it would throw until the guest's readable field set was widened.

**Consequences.** Ordering reflects "last touched by anything" rather than "last changed in Jira". The
guest permission set was not widened for a field the visitor never sees, and the key appears in no
DTO.

### ADR-014 — The epic DTO carries no identifier

**Origin:** From spec

**Decision.** Four fields: title, status, totalChildren, completedChildren. No id, no auto number, no
external key.

**Context.** The spec enumerated four fields and said "nothing not on that list". The list component
keys rows on the array index, so no identifier is needed.

**Consequences.** An untitled epic is labelled in the component rather than falling back to a record
number. The key set is asserted exactly, so publishing a fifth field is a deliberate act.

---

## The board

### ADR-015 — The epic view is the same board, laid out by the same columns

**Origin:** Directed — replaced an earlier Proposed decision

**Decision.** Both views run through one `toColumns(cards, decorate)` helper and share the configured
`columns` property. The task view passes a decorator that nests children under parents; the epic view
passes nothing.

**Context.** Step 4 shipped In flight / Recently completed groups, which made the epic view a second
layout rather than a second reading of the same board. The owner then supplied forward context: the
epic view is meant to condense Jira work into epics and **share the board with Asana tasks**. Two
sources landing in one set of columns is only cheap if the columns are already the shared thing.

**Consequences.** Epic columns follow the same configuration as the tasks; an epic whose status no
column accounts for lands in an Other region; per-column counts and empty states come for free. Adding
an Asana source means adding cards to that input, not adding a view. The server still caps completed
epics at three, so the Done column is bounded by construction and the cap cannot drift from the
layout.

### ADR-016 — The toggle is a real button; the cards stay inert

**Origin:** Proposed

**Decision.** The view toggle is a `<button>` with `aria-pressed`. `publicEpicCard` carries no role,
no tabindex and no handlers.

**Context.** The inertness rule exists for things that look actionable but are not. A view control
genuinely is actionable.

**Consequences.** Build 05's test asserting the board contained zero buttons was rewritten rather than
deleted — the same treatment build 05 gave `GuestAccessTest`. The guarantee was never "no buttons", it
was "no control that could act", and it now asserts every button is a view toggle.
