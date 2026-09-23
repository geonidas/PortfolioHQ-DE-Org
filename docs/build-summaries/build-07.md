# Build 07 — Asana as a second source system

**Status:** complete and live. The manual Asana setup was done after the ninth step, and
everything the original nine steps could only assert in tests has now been exercised against real
Asana: a registered webhook, tasks syncing in, statuses moving in both directions, and six Asana
work items rendering on the public board alongside Jira's.

Meeting live Asana cost four more steps, and they are the substance of this summary rather than a
postscript. Two were defects the tests could not have found, one was a reversal of a decision made
inside this same build, and one closed a gap the build itself opened. The pattern behind three of
the four is recorded under "Mistakes worth recording": every one was a path verified as the
**wrong user**.

**Verified:** 316 Apex tests, 100% pass; 72 Jest; eslint and prettier clean; site republished; the
public board answers an anonymous visitor with HTTP 200 and exactly one SOQL query.

Thirteen commits on `feature/first-branch`.

---

## What build 07 delivered

**Interface changes, made while there was one implementer**

- `InboundChange.iterationRef` — a nullable two-field reference, filled by nobody. Jira will use
  it for sprints in a later build; Asana never will.
- `parseInbound(String)` became `parseInbound(List<Webhook_Event__c>)`, returning
  `List<InboundChange>` correlated by `sourceEventId`. The batch is the unit because hydration is
  only affordable in batches.
- Project linkage now follows a move instead of freezing a stale link.

**Secret storage**

- `Webhook_Secret__c` — a write-only staging row. `WebhookSecretStore` stages and reads;
  `scripts/apex/promote-webhook-secret.apex` carries values into protected Custom Metadata.

**The endpoint**

- `AsanaWebhookResource` — one URL, three branches, keyed on which header arrived.

**The adapter**

- `AsanaAdapter` — batch hydration through Asana's `/batch` endpoint, the membership rule, the
  completion override, and a two-write outbound push.
- `Field_Mapping__mdt` and `FieldMappingService` — vendor value mappings read in both directions.

**Type handling**

- `Work_Item__c.Source_Type__c` — the raw vendor string, never public.

**The board**

- `BoardSourceRules` and `PublicCard.condensesIntoEpic` — the epic toggle became a per-source
  transform without any method branching on a vendor.

---

## Decisions, and why

### 1. The secret could not live where the brief said, and finding out changed the design

The step called for one Encrypted Text field, readable by the integration owner and not by the
guest. It was built that way first. Every assumption under it turned out to be false, and each
one was measured rather than reasoned about:

| Check                                                            | Result                                                          |
| ---------------------------------------------------------------- | --------------------------------------------------------------- |
| `EncryptedText(175)` deploys                                     | yes                                                             |
| Apex reads it in clear                                           | **no — `****`** without the `ViewEncryptedData` user permission |
| System mode bypasses that permission                             | **no** (A/B with field-level security held constant)            |
| A guest permission set can hold that permission                  | **no** — deploy succeeds, org keeps it `false`                  |
| Guest licence allows `Edit` on a custom object                   | **no** — refused at deploy                                      |
| Guest reads a field with no field-level security, in system mode | **no** — `No such column`                                       |
| Guest reads a row **it wrote itself**, in system mode            | **no** — `wrote=true, readBack=null`                            |

The last line is the wall. A site guest cannot read _any_ custom-object row, even one it just
created, even through a `without sharing` class. That is the Guest User Security Policy, and
`JiraWebhookResource` already relied on it for its rate-limit comment without anyone having
measured it.

The endpoint runs as the guest, so the secret it verifies against cannot live in a custom object
field. What shipped instead:

- The handshake **stages** the secret on `Webhook_Secret__c`. Writing is the one thing the guest
  can do, and being unable to read it back is a property of the platform rather than of our
  configuration — which makes it a stronger guarantee than field-level security would have been.
- Verification reads **protected Custom Metadata**, which Apex reads with no object grant, no
  field-level security and no sharing rule, from any user including the guest. That is not a new
  bet: it is how the Jira webhook has verified since build 02.
- A script promotes one to the other, run by hand beside the curl that registers the webhook.

**The ceiling this exposes is lower than the brief assumed.** Encrypted Text buys masking in the
UI, in reports and in exports — but not from Apex, and not for the user that needs the value.
Salesforce has no secret store that Apex can read and a person cannot, and Shield would not
change it. The production shape is unchanged and now better motivated: terminate the webhook at a
gateway, verify there against a secret manager, forward to Salesforce over OAuth JWT so the
platform never holds the secret. `AsanaWebhookResource.signatureVerifiedUpstream` is the seam.

### 2. The batch is the unit, and the transaction is ordered around it

Asana's payloads name a resource gid and an action and carry nothing else, so applying one means
fetching the task. A per-event `parseInbound` would fetch one task at a time and fail half way
through a loop the caller cannot resume. Batch-shaped, the adapter deduplicates the gids a
delivery refers to and fetches ten per request.

The cost is a rule that fails silently when broken: **no DML may happen before `parseInbound`**,
because Apex refuses a callout after uncommitted work — and it refuses it for Asana only, with an
error that never mentions Asana. Written onto the interface, into `CLAUDE.md` and into the
handoff, because the ordering happened to be safe and nothing enforced it.

### 3. The completion flag overrides the section

Asana's completion checkbox is independent of sections and is the easiest way in the UI to finish
something: it sets `completed: true` without moving the card. Inbound, `completed` wins over
whatever the section says. Outbound, a status change writes **both** — the section move and the
flag — because writing one authors exactly the contradiction the inbound rule exists to absorb.

### 4. Type splits in two rather than widening

`Type__c` stays a restricted picklist because it is read by epic resolution and reaches the
public board; a free-text type would publish whatever somebody typed into Asana, and nobody would
notice because `Type__c` is not a field anyone thinks of as free text. `Source_Type__c` holds the
raw string, on no DTO and no guest permission set. The group-by over unmapped rows is what decides
which raw values earn a picklist entry — evidence rather than guesswork.

### 5. The board branches on a boolean, not a vendor

`BoardSourceRules` answers one question — does this system's work roll up into epics — and
`PublicBoardController` publishes the **answer**. The client gets `condensesIntoEpic` and never
learns which tools this org runs. Build 06's decision 10 paid for itself exactly as intended:
no new Apex method, no new parameter, no second layout.

---

## What meeting live Asana changed

**Step 10 — hydration could not run where it was placed.** The first real delivery returned
`Callout from triggers are currently not supported`. `AsanaAdapter` must fetch a task because
Asana's payloads name a gid and an action and nothing else, and the inbound entry point is a
platform event subscriber — a trigger. Every test called `WorkItemInboundProcessor.process`
directly, so nothing ever ran the adapter as the thing that actually runs it.
`WorkItemInboundQueueable` now sits between them, which also gave the outbound and inbound paths
one shared answer to "where do callouts happen".

**Step 11 — typing from the Format field.** Asana's type comes from a customer-named custom
field, which the build flagged as an invented convention. Live, it is `Format`, and it is keyed on
the enum option gid rather than the display name, so renaming an option in Asana does not break
the mapping.

**Step 12 — `Is_Public__c` was never a write rule, and step 8 was wrong to make it one.** Step 8
added `item.Is_Public__c != true` to `WorkItemTriggerHandler.isPushable`, on the reasoning that a
public item is a showcase mirror whose remote system owns the truth. That conflated two questions.
`Is_Public__c` answers who may READ a record — it is the guest board's gate, enforced in
`PublicWorkItemSelector`'s `WHERE` clause and in the guest sharing rules. Who may WRITE it is a
permissions question, and the answer does not change because a visitor can see the card. The
effect was that the internal board's status control silently stopped working on exactly the
records the portfolio exists to show off, Jira's included. Removed, with two tests that fail if it
returns.

The same step made inbound inherit the project's `Is_Public__c` on creation. The field defaults to
false, so before it every synced item arrived invisible and stayed invisible until somebody ticked
a box — no error when that was missed. Inherited rather than defaulted true, so work synced into a
private project is not published by arriving over a webhook; and creation-only, so an item
unpublished by hand is not republished by the next delivery.

**Step 13 — the "next run" that did not exist.** `WorkItemInboundProcessor` had always said of a
delivery the adapter returned nothing for that the row is "left still Pending, for the next run to
pick up". Nothing swept Pending rows, so that sentence described an intention rather than a
mechanism, and thirty rows had collected behind it. `WorkItemInboundSweeper` retries a delivery
three times and then retires it to `Ignored`; `IntegrationDataPurge` holds both audit tables at
their fifty most recent rows nightly. The ceiling matters more than the retry — a sweeper without
one re-reads the stuck rows for ever until its own query hits a governor.

---

## Verdict on build 06's bets

| Bet                                                                         | Verdict                                                                                                                                 |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `IWorkItemAdapter` as the seam for a second system                          | **Paid.** Asana is a new class, a factory line and nothing else. `WorkItemInboundProcessor` gained no branch on system                  |
| Epic view rebuilt onto the same columns so a second source lands in one set | **Paid.** Step 9 added one boolean to a DTO and one rule class                                                                          |
| `lwc/boardLayout` importing no Apex                                         | **Paid.** Shared by both boards through this build, unchanged                                                                           |
| Constants classes replacing picklist literals                               | **Paid.** Three new classes used them from the first line                                                                               |
| Exact DTO key-set assertions                                                | **Paid twice.** Both new public fields failed the assertion first                                                                       |
| `GuestAccessTest` asserting the guest's reach                               | **Paid three times.** Failed on every widening, unprompted                                                                              |
| Hardcoded `STATUS_ALIASES` "is the table `Field_Mapping__mdt` will replace" | **Half paid.** The table exists and Asana uses it; Jira's aliases were left alone rather than migrated, so there are now two mechanisms |

---

## Mistakes worth recording

- **A vacuous assertion, of exactly the kind build 06 shipped.** `Limits.getCallouts()` read
  _after_ `Test.stopTest()` reports the outer limits context, so a no-callout assertion passed
  even with a real callout added. Found only because the test was deliberately broken first.
  Both readings now happen inside the window.
- **A map keyed on `Webhook_Event__c.Id`** answered every event with the same task when the Id
  was null, so an unreadable delivery came back carrying another task's change. Parallel lists
  now; position is the honest key.
- **`String.escapeSingleQuotes` used to build JSON.** It is a SOQL helper and emits a backslash
  before an apostrophe, which is not a valid JSON escape — so a section named
  "Someone else's column" produced a body the adapter could not parse, and the test read that as
  the membership rule failing.
- **Three reserved identifiers**: `nulls` (SOQL `NULLS FIRST`), `into` (SOQL `INTO`), and the
  case-insensitive shadowing trap again, where a `scenario` field hid its own `Scenario` enum.
- **The `PermissionSet.description` 255-cap, twice.** The handoff warns about it; the assertion
  in the edit script caught it both times rather than the deploy.
- **Three defects, one mistake: verifying a path as the wrong user.** The guest-FLS failure on
  inbound DML, the callout-from-trigger defect, and the external credential failure were all found
  live, all after a hand-run check from anonymous Apex passed — and anonymous Apex runs as you.
  Anything reached by a guest, by Automated Process, or by a platform event subscriber has to be
  exercised as that user or the check is vacuous. This is the same family as the
  `Limits.getCallouts()` trap above: a green result that measured the wrong context.
- **A half-fix that was worse than no fix.** `IntegrationDataPurge` excluded Pending rows from its
  delete but counted them towards its cap, so five stuck deliveries silently cost five rows of
  real history — backwards in precisely the case that makes history worth reading. Caught by the
  test that asserted the documented behaviour rather than the written one.
- **An `@AuraEnabled` scan that flagged its own documentation.** `WebhookSecretStore` explains
  why it is never `@AuraEnabled`, and a substring search read the explanation as the violation.

---

## Open items carried forward

| Item                                                                                                                                                                                                                                                   | Trigger point                       |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------- |
| ~~The whole manual Asana setup~~ **Done.** Project record, `Field_Mapping__mdt` rows for six Format options and three statuses, webhook registered, secret promoted                                                                                    | Closed                              |
| Asana's type comes from a custom field this project named. Live it is **`Format`**, keyed on the enum option gid so renaming an option in Asana does not break the mapping. "Article / paper" is deliberately unmapped - `Type__c` has no value for it | When an article is added            |
| Nothing enforces deleting a `Webhook_Secret__c` staging row after promotion; the script only says to. The Asana row was deleted by hand                                                                                                                | Next registration                   |
| Rotating a secret means **deleting** the staged row first — `Resource_Id__c` is unique and the guest cannot update                                                                                                                                     | At first rotation                   |
| Promotion is manual. A platform event plus a Metadata API deployment from the Automated Process user would automate it, if that user can deploy metadata — untested                                                                                    | If re-registration becomes frequent |
| Flat items are always visible on the board, so a Done column of finished Asana work grows unbounded. The orphan cap does not apply to them                                                                                                             | At volume                           |
| `JiraAdapter` still uses hardcoded `STATUS_ALIASES` / `TYPE_ALIASES` while Asana uses `Field_Mapping__mdt`. Two mechanisms for one job                                                                                                                 | Next time a Jira mapping changes    |
| ~~`Retry_Count__c` still inert~~ **Closed.** It is the sweeper's retry counter                                                                                                                                                                         | Closed                              |
| Unresolved parent references are never back-filled                                                                                                                                                                                                     | Carried from build 06               |
| Epic card title truncation                                                                                                                                                                                                                             | Carried from build 06               |

---

## Verified against live Asana

Every criterion the original nine steps could only assert in tests:

- A webhook registered and answering; a handshake staged and its secret promoted.
- A task created in Asana producing a `Work_Item__c` with the right title, project, status and
  `Source_Type__c`.
- Moving a task between sections updating `Status__c`; the completion flag honoured.
- **Outbound**: a status change in Salesforce moving the task in Asana. Verified by hand.
- A tampered signature returning 401 — four rejected deliveries are recorded, bodies not stored.
- Asana items rendering on the public board in a logged-out browser, alongside Jira's.

**One criterion was deliberately abandoned rather than met.** "A public Asana item's status change
does not write to Asana" was step 8's rule, and step 12 removed it — see above. A public item is
now editable from Salesforce exactly like a private one, which is what the project is for.

---

## Version 1 is feature complete

Build 08 is design and UI, after which this goes live as version 1 of the unified cross-platform
project resource manager demo. Version 2 is refinement, and the Big Object archive is its first
item: `IntegrationDataPurge` currently deletes what that archive would otherwise keep, which is a
known and accepted trade for version 1 rather than an oversight.
