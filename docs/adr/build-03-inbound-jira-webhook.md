# Build 03 — Inbound Jira Webhook: Decision Register

Architecture decisions taken while building inbound sync from Jira into Salesforce.
Recorded so none of it gets re-litigated from memory.

| | |
|---|---|
| **Build** | 03 — inbound webhook |
| **Branch** | `feature/first-branch` |
| **Decisions** | 24 |
| **Tests** | 133 passing |
| **Components** | 233 validated |
| **Open items** | 4 |
| **State** | Validated, **not deployed**. No live Jira traffic. |

**Origin labels used below**

- **From spec** — written into Build 03's requirements.
- **Directed** — a decision the owner made when asked.
- **Proposed** — an implementation choice the spec left open.
- **Departs from spec** — a deliberate deviation, with reasoning recorded.

---

## Loop prevention

Both directions are live after this build. A Salesforce edit pushes to Jira, Jira fires a
webhook, the webhook writes Salesforce — and without intervention that cycle never stops.

### ADR-001 — Loop prevention takes three mechanisms, not two

**Origin:** Departs from spec

**Decision.** Add a status-delta check on the outbound trigger alongside the specified
suppression flag and timestamp comparison. Only push when `Status__c` actually changed.

**Context.** The spec named two mechanisms. Neither stops the echo of our own push.
Suppression is a static, so it dies at the transaction boundary — the webhook describing our
own change arrives in a *new* transaction where the flag is long gone. The timestamp check
cannot stop it either, because each cycle genuinely **is** newer: Jira's `updated` advances
every time round.

**Consequences.** The delta check is the load-bearing guard; the other two are narrower. It
also protects something that already existed — Build 02's sync writes `Sync_Status__c` and
`Last_Synced__c` back after every run, and without a delta check every outbound sync would
re-trigger itself.

### ADR-002 — Build the outbound trigger in this build

**Origin:** Directed

**Decision.** Create `WorkItemTrigger` now rather than deferring it, so loop prevention is real
and testable instead of theoretical.

**Context.** No trigger existed. Outbound sync only ever ran when called explicitly, so the loop
described in the spec was hypothetical, and the acceptance criterion "no outbound callout
results from that inbound update" would have passed vacuously.

**Consequences.** Immediately exposed a latent break: Build 01's
`externalIdSupportsUpsertWithoutDuplicating` flips 200 records from `Unspecified` to
`In Progress`, which the new trigger reads as 200 real status changes and pushes to Jira with no
mock set. Fixed by suppressing outbound in that test, with a comment stating the test's actual
scope. Deferring the trigger would have hidden this until later.

### ADR-003 — Suppression is a depth counter, not a boolean

**Origin:** Proposed

**Decision.** `SyncContext` tracks nesting depth. An inner resume must not lift an outer block.

**Consequences.** Nested suppression regions unwind correctly, and surplus `resumeOutbound()`
calls cannot drive it negative. Asserted by `suppressionUnwindsByDepthNotByFlag`.

### ADR-004 — Check suppression before enqueuing, never inside the job

**Origin:** Proposed

**Decision.** The trigger handler tests `SyncContext.isOutboundSuppressed()` synchronously, then
decides whether to enqueue.

**Context.** A static lives for one transaction. Checking the flag inside the Queueable would be
checking a fresh, empty context — it would always read "not suppressed" and the guard would
silently do nothing.

---

## Execution context

The endpoint is reachable without authentication. Getting the real work out of the guest user's
hands was the point of the async design.

### ADR-005 — A platform event, because it actually changes the running user

**Origin:** From spec

**Decision.** The endpoint publishes `Webhook_Event_Received__e`; a subscriber trigger does the
processing.

**Context.** Platform event subscriber triggers run as the **Automated Process** user. The
alternatives do not switch context at all — a Queueable enqueued from the guest transaction runs
*as the guest*, and so does a future method. The remaining option, a `without sharing` class on
an unauthenticated endpoint, is exactly what this design avoids.

**Consequences.** Subscriber failures retry roughly ten times and then the event is dropped,
which is why `Webhook_Event__c` is the durable record rather than the event itself.

### ADR-006 — Publish after commit, not immediately

**Origin:** Proposed

**Decision.** `PublishAfterCommit`, so an event exists only for a delivery that actually
persisted.

**Context.** The opposite of the Build 02 logging decision, for the opposite reason. There,
`PublishImmediately` was attractive precisely because it survives rollback. Here, an event for a
row that rolled back would point at nothing.

### ADR-007 — The event carries a record id and nothing else

**Origin:** Proposed

**Decision.** One `Webhook_Event_Id__c` field. The subscriber re-reads the row for the payload.

**Consequences.** Keeps the event small, keeps one durable copy of the payload, and avoids
platform event size limits on bodies that can reach 128 KB.

---

## Secret handling

Guest-reachable code has to read a signing secret the guest must never see, and no value may
ever enter source control.

### ADR-008 — Protected custom metadata, failing closed in every direction

**Origin:** From spec

**Decision.** A missing record, an inactive record, and a blank value are indistinguishable to
callers. All three return null, and null always means reject.

**Context.** Protected metadata is readable by Apex in this org but cannot be queried out of it
by a user — the exact shape a secret needs when unauthenticated code must use it.

**Consequences.** There is no code path where "not configured" degrades into "skip validation".
A freshly deployed org accepts nothing, which is an acceptance criterion in its own right.

### ADR-009 — Ignore the records directory before any record exists

**Origin:** From spec

**Decision.** `force-app/main/default/customMetadata/` added to both `.forceignore` and
`.gitignore` as the first act of the build.

**Context.** Ordering is the whole point: gitignore cannot untrack a file already committed.
Verified by dropping a file at the exact path a real record would occupy and confirming
`git check-ignore` catches it.

**Consequences.** The `.forceignore` entry also means a later `retrieve` cannot pull the secret
into source by accident — the other way this normally leaks.

### ADR-010 — Pin the DeveloperName as a literal

**Origin:** From spec

**Decision.** Code reads the record named exactly `Jira_Webhook`, asserted by a test.

**Context.** The record is created by hand in Setup and never enters source control, so this
constant is the only thing keeping code and org in agreement. If it drifts, the endpoint stops
working with no compile error.

### ADR-011 — Test secrets are generated at runtime

**Origin:** Proposed

**Decision.** `JiraWebhookPayloadFactory.randomSecret()` returns a fresh throwaway key per run.
No literal secret appears anywhere in source.

**Consequences.** Satisfies "no secret value, real or placeholder, in source control" literally,
and proves the code never depends on a particular value.

---

## The endpoint

An unauthenticated POST target. Every decision here is about limiting what a stranger can make
it do.

### ADR-012 — The endpoint parses nothing

**Origin:** Departs from spec

**Decision.** Verify the signature, persist the row, answer. `Event_Type__c` and
`External_Id__c` are left null and filled in later by the processor.

**Context.** The spec said "no parsing of business data" but described `External_Id__c` as
extracted from the payload. Deserializing unauthenticated JSON is where these endpoints get
hurt, and `JSON.deserializeUntyped` on a hostile 128 KB body burns heap and CPU *in the guest
transaction* — the context the platform event exists to escape.

**Consequences.** Rejected deliveries keep a null `External_Id__c` forever, since nothing
processes them. Correct — we should not parse payloads we have refused — but visible in the data.

### ADR-013 — Verify over raw bytes, compare in constant time

**Origin:** Directed

**Decision.** HMAC computed on `request.requestBody` as a Blob, compared with
`Crypto.verifyHMac`. The `X-Hub-Signature` header is looked up case-insensitively.

**Context.** Re-serializing a payload changes whitespace and key order, which changes the digest
and breaks every signature — so the signature class only ever sees a Blob. HTTP header names are
case-insensitive by specification and Apex preserves whatever casing arrived, making an
exact-key lookup a latent production failure.

### ADR-014 — Status codes are chosen for what they make Jira do

**Origin:** From spec

**Decision.** `200` for accepted, including payloads that will later be ignored. `401` for an
invalid signature. `500` only when the delivery could not be recorded.

**Context.** A non-2xx is a request to retry, so it is reserved for the one failure where
retrying helps. Claiming success on a failed insert would silently lose a delivery; returning
4xx for unparseable JSON would make Jira retry a payload that can never succeed.

### ADR-015 — Every rejection looks the same from outside

**Origin:** Proposed

**Decision.** A wrong signature and an org with no secret configured return identical status and
body.

**Consequences.** A caller cannot probe whether this org has been configured. Asserted by
`rejectionsAreIndistinguishableFromEachOther`, which compares both responses rather than
checking each in isolation.

### ADR-016 — Unverified bodies are never stored

**Origin:** Directed, then revised once the exposure went live

**Decision.** Store `Raw_Payload__c` only for deliveries whose signature verified. A rejected
attempt is still recorded, but keeps a fingerprint instead of the content: byte count, a SHA-256
prefix so repeat attempts are recognisable, and the offered signature truncated.

**Context.** Originally the full body was stored either way, with the risk noted and deferred.
The risk stopped being theoretical the moment the site went Live — two unauthenticated
reachability probes wrote rows into the org with no credentials at all. Anyone who finds the URL
could POST 128 KB per request, indefinitely.

**Consequences.** A rejected request now costs roughly 106 characters instead of up to 131,072 —
about a 600-fold reduction — while keeping enough to recognise a flood or correlate repeats.
Verified bodies are still stored byte-for-byte, which processing depends on.

**Rejected alternative: a row-count cap.** Capping rejected rows means counting existing ones,
and the endpoint runs `with sharing` as the guest user, who cannot read the rows it creates. The
count would silently return zero and the cap would never fire. Making it work would need a
`without sharing` class reachable from an unauthenticated endpoint — the one thing this design
refuses. Row growth is therefore still unbounded, just 600 times slower per request.

---

## Data model

### ADR-017 — Deliveries use Private sharing, unlike every other object here

**Origin:** Proposed

**Decision.** `Webhook_Event__c` is `sharingModel: Private`.

**Context.** Not a style inconsistency. Salesforce forces guest record access to Private, and a
public sharing model blocks the guest grant outright at deploy time.

**Consequences.** Directly caused ADR-018 — with Private sharing and guest-created rows, nobody
could read the audit trail.

### ADR-018 — View All on deliveries, reversing a rule set in Build 01

**Origin:** Departs from earlier builds

**Decision.** `Portfolio_HQ_Developer` gets `viewAllRecords` on `Webhook_Event__c` only.
`modifyAllRecords` stays false everywhere.

**Context.** Builds 01 and 02 deliberately kept View All and Modify All off on every object,
twice reviewed. ADR-017 makes that stance produce an audit object its owner cannot see.

**Consequences.** A scoped exception to a deliberate rule, not an oversight. Reversible if
querying as an admin with View All Data is preferred.

### ADR-019 — Deliveries store namespaced external ids

**Origin:** Directed

**Decision.** `Webhook_Event__c.External_Id__c` holds `jira:10039`, matching `Work_Item__c`, so
it is directly the upsert key.

**Consequences.** Not marked unique or External ID — several deliveries legitimately concern one
issue, and uniqueness would reject the second. `Text(50)` fits Jira comfortably; it would be
tight for Asana GIDs, where `Work_Item__c` already uses `Text(100)`.

### ADR-020 — Order by the issue's update time, not the event's

**Origin:** Directed

**Decision.** `Remote_Last_Modified__c` comes from `issue.fields.updated`, not the payload's
envelope `timestamp`.

**Context.** The envelope says when the event fired, which on a redelivery is not when the issue
changed. Using it would silently break ordering exactly when Jira retries.

**Consequences.** Jira sends a four-digit offset (`+0000`); the parser inserts the colon before
handing it to the JSON date parser, and accepts both forms.

---

## Mapping and processing

### ADR-021 — One status mapping, reached through the interface

**Origin:** Directed

**Decision.** `normalizeStatus(String)` added to `IWorkItemAdapter`, implemented in `JiraAdapter`
by reading the same `STATUS_ALIASES` table the outbound match already uses.

**Context.** Chosen over a public static so the processor stays vendor-neutral. Two tables would
drift, and drift here means inbound and outbound disagree about what a status means.

**Consequences.** Widening the interface broke the test `FakeAdapter`, which had to implement the
fourth method — the kind of break that only appears at deploy. Extracting the table to custom
metadata later is now one refactor, not two.

### ADR-022 — An unmapped Jira status applies but never claims to be Synced

**Origin:** Proposed

**Decision.** Status becomes `Unspecified`, `Sync_Status__c` stays `Pending`, the event reaches
`Processed`, and the unmapped name is written to the event's error message.

**Context.** Build 01's validation rule blocks `Synced` alongside `Unspecified`. Inbound hits
this whenever Jira reports a status with no mapping — "Blocked", say. An interaction between
three builds that only shows up at runtime.

**Consequences.** Honest on both counts: the change was applied, and the two systems are not
truly reconciled.

### ADR-023 — Within a batch, the newest delivery per issue wins

**Origin:** Proposed

**Decision.** Collapse deliveries by external id, keep the latest by timestamp, mark the rest
`Ignored` as superseded.

**Context.** Jira does not guarantee ordering, and a bulk batch can carry several deliveries for
one issue. Without this, arrival order decides the outcome and a batch can apply an older state
last.

---

## Access and testing

### ADR-024 — Tests are indifferent to how the org is configured

**Origin:** Corrected during the build

**Decision.** Secret state is always injected, never inferred from the org. The real metadata
lookup is exercised against a DeveloperName no record can ever hold.

**Context.** The spec warned that tests must not depend on a real secret record *existing*. The
first version made the mirror-image mistake: it depended on one *not* existing, and failed the
moment the `Jira_Webhook` record was created — while the code was working correctly.

**Consequences.** Chasing it down surfaced a second, quieter fault.
`anUnconfiguredOrgRejectsEverything` was passing for the wrong reason: a random secret simply did
not match whatever the org held, so it tested "wrong signature", not "no secret configured". It
would have kept passing forever without ever testing its own name.

**Also decided here.** Guest access is asserted against permission-set metadata rather than
runtime behaviour, because a fresh scratch org may have no site and therefore no guest user; the
runtime `runAs` check runs opportunistically when one exists. And loop prevention carries a
**negative control** — `anOrdinaryStatusChangeDoesEnqueueAnOutboundCall` — so the main test
cannot pass merely because the trigger never fires.

---

## Open questions

Deliberately unresolved. None blocks the build; each has a known trigger point.

### Automated Process user and field-level security — *watch the first webhook*

The processor writes `Work_Item__c` as the Automated Process user, which cannot be assigned a
permission set. Build 01 proved this org enforces FLS on DML in a place the documentation says it
should not. Trigger code does run in system mode, so this probably will not bite — but no test
can tell us, because tests run as the developer. Symptom: deliveries reach `Failed` with an
inaccessible-fields message and nothing else reports an error.

### The Experience site is not activated — *before live traffic*

Network status is `UnderConstruction`. The site at `/neoGeoTest` is Active, but an unactivated
Experience network serves an under-construction page to public traffic rather than routing to
Apex REST. Jira cannot reach the endpoint until this changes — and it will look like a code fault
when it happens.

### `Retry_Count__c` is inert — *cosmetic*

The field ships because the spec asked for it, but retry policy is out of scope, so nothing
writes it. Expect null or zero on every row until that policy exists. Recorded in the field's own
description.

### Page layouts are bare on every object — *cosmetic*

Metadata API deploys create fields but never place them on layouts — which is why
`Secret_Value__c` was invisible in Setup until a layout was added. The same is true of
`Project__c`, `Work_Item__c` and `Integration_Log__c`. Nothing in the build depends on it; it
only shows when inspecting records by hand.

---

## Proven versus assumed

What the 127-test suite and the validated deployment actually establish — and what they cannot.

| Claim | Status | Evidence |
|---|---|---|
| Deploy and `RunLocalTests` pass | **Proven** | 127/127, 233 components, validation `0AfE200000psAOSKA2` |
| An unconfigured org rejects everything | **Proven** | Injected unconfigured state, not inferred |
| Duplicate delivery creates one record | **Proven** | Same payload twice: one Processed, one Ignored |
| Stale deliveries do not overwrite newer state | **Proven** | Older event after newer, and batch-collapse ordering |
| Inbound processing enqueues no outbound call | **Proven** | Plus a negative control proving the trigger does fire otherwise |
| Guest cannot reach restricted objects | **Proven** | Permission-set grants asserted; org shows zero grants |
| 200 deliveries stay within limits | **Proven** | Two DML statements regardless of volume |
| Processing survives as Automated Process | **Untested** | Tests run as the developer; only a live webhook settles it |
| Jira can reach the endpoint at all | **Untested** | Site not activated |
| End-to-end round trip against real Jira | **Untested** | Outbound was verified live in Build 02; inbound has not been |
