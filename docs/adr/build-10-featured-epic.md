# ADR — Build 10: featured epic

Decisions taken for build 10, with the reasoning that would otherwise be lost. Decisions 1-14 were
made by the owner before the build started and are recorded here at step 0, as given. Where step 0
found something that bears on a decision, it is written under that decision. The questions it
raised for the owner are at the end. Narrative will live in `docs/build-10/summary.md`; org state
and traps live in `docs/handoff.md`.

The build: the owner features one epic on the public board, from a button on that epic's card on
the internal board. With an epic featured, the public board opens in Tasks and shows that epic's
tasks. With none featured, it opens in Epics. Both boards mark the featured epic in the Epics view.

---

## Step 0 findings, 2026-09-26

### Baseline

- Branch `feature/first-branch` at `6892946`. No branch created. `docs/images/` is untracked; it is
  the owner's and was left alone.
- Scratch org `MyScratchOrg` is active and expires **2026-10-05**, nine days after step 0.
- Build 09's suite is green: **461** Apex tests, `RunLocalTests`, 0 failures (run `707E200002DiEGu`);
  **271** Jest; eslint and prettier clean.

### Epic membership: `EpicRollup` and the Epics view agree

Counted three ways, read-only: `EpicRollup` in anonymous Apex over the rows each board loads
(`WorkItemSelector.forBoard(null)` and `PublicWorkItemSelector.publicBoardItems()`); the rendered
Epics view, read with headless Chrome - the public board logged out in a fresh profile, the
internal board signed in as the owner; and each epic's direct children, for comparison.

| Epic                | Status      | Internal: `EpicRollup` | Internal: Epics view | Public: `EpicRollup` | Public: Epics view   | Direct children, internal / public |
| ------------------- | ----------- | ---------------------- | -------------------- | -------------------- | -------------------- | ---------------------------------- |
| WI-0000 (`DOPP-1`)  | In Progress | 2 of 9                 | "2 of 9 done"        | 1 of 4               | "1 of 4 done"        | 7 / 3                              |
| WI-0001 (`DOPP-15`) | Done        | 0 of 0                 | "No child items yet" | 0 of 0               | "No child items yet" | 0 / 0                              |

They agree on both boards. The members are:

- **Internal, WI-0000:** WI-0002, WI-0003 (through WI-0002), WI-0004 (through WI-0002), WI-0005,
  WI-0006, WI-0010, WI-0012, WI-0013, WI-0014.
- **Public, WI-0000:** WI-0002, WI-0003 (through WI-0002), WI-0005, WI-0006. These are the four Jira
  cards the public Tasks view shows today. The other six public cards are Asana's, and Asana is
  flat.

**"Direct children" and "as its card counts them" are two different sets.** Decision 4 says both.
The card counts every descendant whose nearest epic ancestor is this epic, not direct children
alone: ADR build-06, ADR-011, "a subtask two hops down counts". WI-0003 is a Story under the Story
WI-0002, so it is in WI-0000's count of 4 and is not a direct child. The two readings differ by one
card on the public board today (see question 2).

**Where the links come from.** WI-0003 → WI-0002 matches Jira: `DOPP-17`'s stored payload names
`DOPP-16`. WI-0005 and WI-0006 are linked to WI-0000 **in Salesforce only**. Their latest Jira
payloads carry no `parent`, and the build 06 seed script (`flag-public-demo-data.apex`) made the
link. Inbound assigns a parent only when a payload carries one, so Jira deliveries leave those
links alone. **WI-0001 is an epic in Salesforce only** too: the seed script overwrote its
`Type__c` (see decision 7).

### Unresolved parent references

Nothing in the org records one any more, so the count can only be partly answered here.

- **No field stores an unresolved reference.** That has been an open item since build 06: closing it
  needs a `Parent_External_Id__c` or a reconciliation job. The only record is the Inbound
  `Integration_Log__c` row that `WorkItemInboundProcessor` writes ("Parent ... is not a
  Work_Item__c Salesforce has seen"). `IntegrationDataPurge` keeps 50 log rows. The oldest one left
  is from 2026-09-25 23:41 UTC, and none of the 50 names a parent.
- **The stored payloads show none.** 27 Jira `Webhook_Event__c` rows cover 6 of the 14 Jira issues.
  For each of the 6, the parent its latest payload names exists in Salesforce and is the parent
  held.
- **Eight Jira issues have no stored delivery:** WI-0001, WI-0002, WI-0004, WI-0007, WI-0009,
  WI-0010, WI-0012 and WI-0014. Six of them hold a parent or are epics. Only **WI-0007** (`DOPP-21`,
  Task) and **WI-0009** (`DOPP-3`, Unspecified) are non-epics with no parent. Either could be an
  unresolved reference or simply parentless. Both are private.
- **No public card is affected today.** Every public non-epic Jira card (WI-0002, WI-0003, WI-0005,
  WI-0006) resolves to WI-0000. The canary WI-0011 has no `External_Id__c` and so no reference.
- Which epic WI-0007 or WI-0009 would belong to needs Jira: one read-only search of `DOPP`
  returning each issue's parent. **Not run**, because this build calls neither tool (question 5).
- Not back-filled. Carried as an open item.

---

## 1. The featured epic is a hierarchy custom setting's org default

**Decision.** A hierarchy custom setting's org default holds the epic's Id. There is one by
construction. No field on `Work_Item__c`, so the sync trigger never runs for it and the guest's
readable fields do not change. It is data: it does not deploy, and after the move to the Developer
Edition org it is set again.

**Notes from step 0.** Reading the org default (`getOrgDefaults()`) costs no SOQL, which is what
keeps the public board at one query (invariant 2). A custom setting cannot hold a lookup, so the
field is Text(18). Whether the site guest's Apex can read the setting with no grant to
`Portfolio_HQ_Guest` is proved live and logged out in step 2, not assumed. If it needs no grant,
`GuestAccessTest` gains an assertion that the guest holds none, so the setting cannot be read by
any path except the controller.

## 2. Setting and clearing are new controller methods, behind a custom permission

**Decision.** Set and clear are new methods, not arguments to `saveDetails`, so a board left open
across the deploy is unaffected. They sit behind a new custom permission,
`Portfolio_HQ_Feature_Epic`, and never touch `Pending_Push_Fields__c`, a push job or an adapter.

## 3. The server accepts only an epic

**Decision.** The server accepts only an epic, as `EpicRollup` defines one (`Type__c` Epic). Any
other Id is refused with a reason.

**Note from step 0.** An epic that is not public is still an epic, so it would be accepted. The
public board could never show it (question 4).

**Amended by the owner's answer to question 4.** The server accepts an epic the public board can
show: the epic and its project both public. Anything else is refused with a reason that says which
condition failed. Reading back uses the same rule (decision 7).

## 4. Membership comes from `EpicRollup`

**Decision.** Membership comes from `EpicRollup`: an epic's direct children, as its card counts
them. Subtasks are not shown anywhere and stay that way; they are version 2.

**Notes from step 0.** See the findings above and question 2: the card counts descendants, not
direct children. On subtasks, Jira's Sub-task maps to `Task` (ADR build-06, ADR-005), so a subtask
is an ordinary card and is not marked as a subtask anywhere. There is one, WI-0008 (`DOPP-12`). It
is private and sits under WI-0009, which has no epic. It shows on the internal board today, nested
under WI-0009. Whichever reading is chosen, this build **only removes cards** from the public Tasks
view. No card that is hidden today becomes visible.

**Settled by the owner's answer to question 2.** Membership is as the card counts it:
`EpicRollup.epicOf`, every item whose nearest epic ancestor is this epic. "Direct children" is not
the rule. Under a featured epic, the Tasks view shows exactly the number on its card.

## 5. Flat items are unchanged

**Decision.** Items that belong to no epic appear on the public board exactly as settled in earlier
builds, in every view and source. This build filters only the items that belong to epics. The rule
is expressed through `EpicRollup` and metadata, never a vendor check.

## 6. Featured: the public Tasks view shows only that epic's epic-linked items

**Decision.** With an epic featured, the public Tasks view shows only that epic's items among
epic-linked items, with a line: "Showing tasks from [epic title]".

## 7. None featured: the public board opens in Epics

**Decision.** With no epic featured, the public board opens in the Epics view. The Tasks view shows
a note: "No epic is featured right now, so no epic tasks are shown." A featured Id that no longer
resolves to an epic (deleted, or no longer an epic) is treated as none.

**Note from step 0.** WI-0001 is an epic in Salesforce only (see the findings). If it is the
featured epic, the next Jira delivery for `DOPP-15` carrying its issue type turns it back and it is
silently treated as none. That is correct under this decision, and worth knowing before choosing
it.

**Widened by the owner's answer to question 4.** A featured epic that has been made private, or
whose project has, is also treated as none: the rule for reading back is the rule for setting
(decision 3). The stored Id stays in the setting until the owner features another epic or clears
it, so making the epic public again brings it back.

## 8. Featured: the public board opens in Tasks

**Decision.** With an epic featured, the public board opens in the Tasks view.

## 9. The default view applies on load only

**Decision.** A poll that finds a different featured epic updates the indicator, the line and the
Tasks view's content. It never switches the view the visitor is on.

## 10. A featured epic moved to Done stays featured

**Decision.** A featured epic moved to Done stays featured until the owner clears it.

**Note from step 0.** Two rules from earlier builds meet this one (question 3). Tasks under a
finished epic never reach an anonymous visitor (`EpicRollup.keptInPublicTaskView`, build 07). And
only the three most recently updated Done epics get a card (`COMPLETED_EPIC_LIMIT`, build 06).

**Settled by the owner's answer to question 3.** While an epic is featured it is exempt from both:
it keeps its card however many Done epics are newer, and its tasks stay in the public Tasks view
after it is Done. Every other finished epic is capped and withheld as before. The featured epic
can also be set while already Done. The exemption changes what the payloads carry, so it lands in
step 2 with them.

## 11. A Source filter that excludes the featured epic's source says so

**Decision.** When the Source filter excludes the featured epic's source, the Tasks view explains
that the featured epic's tasks are under its source, naming the source by its label from the
payload.

## 12. The indicator is in `boardEpicCard`, driven by the payload

**Decision.** Visible text and an accessible name, not colour; the accent stripe already means
source. Internal: "Featured on the public board". Public: "Featured".

## 13. The internal board's views are unchanged apart from the button and the indicator

## 14. A change reaches the public board on its next poll

**Decision.** Within about 30 seconds. The internal board that made the change refreshes itself;
other open internal tabs catch up on their next refresh, because Change Data Capture does not fire
for a custom setting.

---

## Questions raised at step 0, and the owner's answers

**Answered 2026-09-26: the owner took the recommendation on all five.** Each answer is written
into the decision it amends, above.

**1. What identifies the featured epic on the public payload.** The step 2 spec says both payloads
carry `featuredEpicId`, the epic's Id. The public payload publishes no Salesforce id today:
`PublicCard` keys on the auto number, `PublicEpic` carries no identifier at all, and the controller
and `CLAUDE.md` both say so. A public `featuredEpicId` would be the first Id an anonymous visitor
receives. It would also match nothing on the client, since no public epic or card carries an Id,
so the epic and every card would need one too. **Recommended:** the internal payload carries
`featuredEpicId` as specified (`BoardEpic` already has `id`). The public payload carries answers
Apex has already worked out, and no identifier: `isFeatured` on each epic (both DTOs, so
`boardEpicCard` reads one property from either board). On each public card, whether it belongs to
an epic and whether that epic is the featured one. Apex still resolves membership against the
epics it already has, and the client never does. That is three new public keys, asserted in step 2.
The alternative is to publish record numbers: the featured epic's number, a number on each epic and
each card's epic. The public epic card would then show a number it has never shown.

**2. Direct children, or as the card counts them.** They differ by WI-0003 today. **Recommended:**
as the card counts them, meaning `EpicRollup.epicOf`, the rule ADR-011 set in build 06. The Tasks
view under a featured epic then shows exactly the number on its card, and WI-0003, which the public
Tasks view shows today, stays with its epic rather than vanishing from it.

**3. A featured epic that is Done.** (a) Its tasks are withheld from the public Tasks view by build
07's rule, so the line would read "Showing tasks from X" above none of X's tasks. (b) Past the
three most recent Done epics it has no card, so it has no indicator and no Remove button, and the
public board treats it as none. **Recommended:** while an epic is featured, it is exempt from both.
It keeps its card, and its tasks stay in the public Tasks view. Otherwise decision 10 holds in the
setting but not on either board. That widening is small: those tasks are already public rows the
query loads. The literal reading, change neither rule, is also coherent. Today the only Done epic,
WI-0001, has no children.

**4. An epic that is not public.** It can be set, but the public board cannot see it and treats it
as none, while the internal indicator would say "Featured on the public board". **Recommended:**
set refuses it with a reason, as decision 3 refuses a non-epic. Both epics are public today.

**5. The unresolved-parent count.** Completing it needs one read-only search in Jira, which this
build is scoped not to make. **Recommended:** leave it as the carried open item and re-check after
the move to the Developer Edition org, where the hierarchy arrives by delivery in whatever order
Jira sends it. That is where an unresolved parent is likely.

**Where each answer lands.** Question 1: step 2 (payloads and the key-set assertion) and step 4
(the public client). Question 2: step 2, since membership is computed by Apex. Question 3: step 2
(`EpicRollup`). Question 4: step 1 (the service). Question 5: the carried open items, in step 5's
summary and the handoff.

---

## Built in step 1

- **`Featured_Epic__c`**: a hierarchy custom setting with Protected visibility. Only its org default
  is used. **`Epic_Id__c`** is Text(18), holding the epic's Id, and blank means none.
- **`Portfolio_HQ_Feature_Epic`**: a custom permission in `Portfolio_HQ_Developer`, the internal
  permission set.
- **`FeaturedEpicService`**: `storedId()` (no query), `read()` (the stored Id if it still resolves,
  otherwise null), `feature(Id)` and `clear()`. The rule for what can be featured is one method,
  used by both set and read. `EpicRollup.isEpic` is the definition of an epic, and `EpicRollup`
  itself now uses it too. The service writes the setting's row and nothing else. Who may call it is
  the controller's business (step 3): it checks the permission, and the scripts are run by an admin.
- **`scripts/apex/set-featured-epic.apex`** and **`scripts/apex/clear-featured-epic.apex`**. The
  build spec put them in `scripts/`; they sit in `scripts/apex/` beside every other Apex script.
