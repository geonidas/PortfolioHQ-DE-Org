# Inbound: a webhook becomes a record

A delivery from Jira or Asana, followed from an anonymous POST to an upserted work item. The
endpoint runs as the site's guest user and does almost nothing; the work happens later, as another
user, in a transaction that is allowed to call out.

Concepts: Apex REST on a Salesforce Site, the guest user, HMAC signatures, protected custom
metadata, platform events and their running user, publish-after-commit, record ownership and
sharing, Scheduled Apex.

<!-- stops:start -->

1. [Why does the endpoint parse nothing?](#1-why-does-the-endpoint-parse-nothing)
2. [Why is the signature checked over the raw bytes?](#2-why-is-the-signature-checked-over-the-raw-bytes)
3. [Why does every rejection look the same?](#3-why-does-every-rejection-look-the-same)
4. [Where does the signing secret live, if the guest can't read records?](#4-where-does-the-signing-secret-live-if-the-guest-cant-read-records)
5. [Why does a platform event sit between the endpoint and the processor?](#5-why-does-a-platform-event-sit-between-the-endpoint-and-the-processor)
6. [Why does the subscriber only enqueue?](#6-why-does-the-subscriber-only-enqueue)
7. [Why does the queueable re-read the deliveries?](#7-why-does-the-queueable-re-read-the-deliveries)
8. [Why is the whole batch parsed before anything is written?](#8-why-is-the-whole-batch-parsed-before-anything-is-written)
9. [Why does only the newest delivery per issue apply?](#9-why-does-only-the-newest-delivery-per-issue-apply)
10. [How does the timestamp check stop echoes and duplicates?](#10-how-does-the-timestamp-check-stop-echoes-and-duplicates)
11. [Why does inbound leave pending fields alone?](#11-why-does-inbound-leave-pending-fields-alone)
12. [Why is a field written only when the payload carries it?](#12-why-is-a-field-written-only-when-the-payload-carries-it)
13. [Why are owner and visibility set on creation only?](#13-why-are-owner-and-visibility-set-on-creation-only)
14. [What happens when an issue moves project?](#14-what-happens-when-an-issue-moves-project)
15. [Why are parents linked in a second pass?](#15-why-are-parents-linked-in-a-second-pass)
16. [What picks up the deliveries nobody finished?](#16-what-picks-up-the-deliveries-nobody-finished)

<!-- stops:end -->

## 1. Why does the endpoint parse nothing?

<!-- at: force-app/main/default/classes/JiraWebhookResource.cls | @RestResource(urlMapping='/v1/webhook/jira') -->

[JiraWebhookResource.cls:21](../../force-app/main/default/classes/JiraWebhookResource.cls#L21)

The Jira webhook's endpoint verifies the signature over the raw bytes, inserts one
`Webhook_Event__c` row, and answers. No JSON parsing, no business logic, no callouts, no reads of
any other object. Everything downstream happens off that row, in another transaction, as another
user.

A body is stored only once its signature has proved it came from Jira. A rejected request leaves a
fingerprint instead - its size, a digest prefix and the signature offered - which is enough to
recognise a flood and roughly six hundred times less than a stored body would let an anonymous
caller write.

**Concept.** A Salesforce Site exposes Apex REST resources to unauthenticated callers, who run as the
site's guest user with that user's deliberately small permissions.

**Failure mode.** Deserialising unauthenticated input inside the guest's transaction is attack
surface the endpoint has no use for, and any work done here is work an anonymous caller can make the
org do.

**Pattern: Stage, then act.** The only thing done in the untrusted context is recording that a
delivery arrived. Acting on it is somebody else's job.

## 2. Why is the signature checked over the raw bytes?

<!-- at: force-app/main/default/classes/WebhookSignature.cls | return Crypto.verifyHMac( -->

[WebhookSignature.cls:68](../../force-app/main/default/classes/WebhookSignature.cls#L68)

The HMAC-SHA256 of the request body is computed with the shared secret and compared with the
signature header by `Crypto.verifyHMac`. The verifier only ever sees a `Blob`, never a parsed
object, because parsing and re-serialising a payload changes whitespace and key order, which changes
the digest and fails every signature. The platform's comparison is used rather than string equality
so that timing leaks nothing.

A missing body, a missing header, a missing secret, malformed hex and any exception are all a
rejection, never a bypass. The header is found case-insensitively, as HTTP requires and Apex's map
of headers does not.

**Concept.** A webhook signature is an HMAC of the body under a secret both sides hold; only a
holder of the secret can produce one that verifies.

**Pattern: Fail closed.** Every input that is missing or unreadable means "reject", and there is no
branch in which something not being configured skips the check.

## 3. Why does every rejection look the same?

<!-- at: force-app/main/default/classes/JiraWebhookResource.cls | // One response for every rejection reason. -->

[JiraWebhookResource.cls:77](../../force-app/main/default/classes/JiraWebhookResource.cls#L77)

Status codes are chosen for what they make the sender do. A non-2xx asks Jira to retry, so 500 is
kept for the one case where retrying helps: the delivery could not be recorded. A payload that will
later be ignored still gets 200, because there is nothing to retry. A bad signature gets 401, and so
does every other rejection - a caller must not be able to tell "wrong signature" from "this org has
no secret configured".

Asana adds a clock: a response slower than ten seconds counts as a failed delivery, and a day of
failures deletes the webhook. That is another reason these endpoints only record.

**Pattern: Answer for the caller's next move.** A response is a request to the sender - retry, or
don't - and the one it gets should be the one it ought to act on.

## 4. Where does the signing secret live, if the guest can't read records?

<!-- at: force-app/main/default/classes/WebhookSecretStore.cls | Two halves, because the platform forces them apart. -->

[WebhookSecretStore.cls:4](../../force-app/main/default/classes/WebhookSecretStore.cls#L4)

A site guest can insert a custom object row and can never read one back: not its own, not in system
mode, not through a `without sharing` class. In build 07, object access, field-level security and
View All were granted in turn, and each only moved the error along. So a secret lives in two places.
Asana's registration handshake stages it in `Webhook_Secret__c`, insert only. Verification reads
protected custom metadata, `Integration_Secret__mdt`, which Apex can read as any user. A script run
by an admin carries the value across.

Insert only is also the safer rule: the endpoint is unauthenticated, and an upsert would let anyone
who knows a resource id replace a live secret with their own. No method here is `@AuraEnabled`, and
the secret goes into a local variable and into `verifyHMac`, never into a log.

**Concept.** Custom metadata types are deployable configuration records; protected ones can be read
by Apex in the org but not queried out of it by a user.

**Failure mode.** A secret kept in a custom object field verifies in every test, because tests run as
the admin, and fails every live delivery.

**Pattern: Fail closed.** `IntegrationSecretService` returns null for a missing, inactive or blank
secret alike, and null means reject.

## 5. Why does a platform event sit between the endpoint and the processor?

<!-- at: force-app/main/default/objects/Webhook_Event_Received__e/Webhook_Event_Received__e.object-meta.xml | <publishBehavior>PublishAfterCommit</publishBehavior> -->

[Webhook_Event_Received__e.object-meta.xml:8](../../force-app/main/default/objects/Webhook_Event_Received__e/Webhook_Event_Received__e.object-meta.xml#L8)

Its only job is to change who is running. The `Webhook_Event__c` insert trigger publishes one event
per verified row, carrying nothing but the row's id, and the subscriber trigger runs as the
platform's process user - Automated Process, or the user a `PlatformEventSubscriberConfig` names -
never as the guest.

The event is published after commit, so the subscriber never chases a row whose insert rolled back,
and it carries only the id, so the payload stays on one durable row.

**Concept.** Platform events are publish-and-subscribe inside the org. A subscriber trigger runs in
its own transaction, as the subscriber's configured user, not as the publisher.

**Failure mode.** A queueable enqueued from the guest's transaction would still run as the guest,
with none of the access processing needs. And the subscriber's user is also whose credentials a
callout uses: Automated Process cannot be granted Asana's, which is why the subscriber config, and
the sweeper later in this tour, name a real user.

**Pattern: Know who your code runs as.** The hop exists for its running user, not for decoupling.

**Pattern: Stage, then act.** The staged row is the durable record, and the event only says where
it is.

## 6. Why does the subscriber only enqueue?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | System.enqueueJob(new WorkItemInboundQueueable(eventIds)); -->

[WorkItemInboundProcessor.cls:80](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L80)

The subscriber is a trigger, and Apex refuses a callout made from a trigger. The Asana adapter must
call out while it parses, to fetch the task, so the subscriber hands the batch to
`WorkItemInboundQueueable` and does nothing else - for every system, Jira included, which gains only
the latency of a queued job. It is the shape the outbound path has always had.

**Failure mode.** This is how the first live Asana delivery failed: `Callout from triggers are
currently not supported`, the delivery left staged and nothing created, while every test stayed
green, because every test called `process` directly. Tour 7 has the test that now runs the real
path.

**Pattern: Vendor at the edge.** Enqueueing only the systems that hydrate would mean shared code
knowing which adapters call out, which is the knowledge the adapter seam exists to keep out of it.

## 7. Why does the queueable re-read the deliveries?

<!-- at: force-app/main/default/classes/WorkItemInboundQueueable.cls | AND Processing_Status__c = :DeliveryStatus.PENDING -->

[WorkItemInboundQueueable.cls:50](../../force-app/main/default/classes/WorkItemInboundQueueable.cls#L50)

The job carries ids, not rows, and re-reads them with `Processing_Status__c = Pending` and a valid
signature in the WHERE clause. Between the publish and this job, a delivery can be retired by
another run - superseded in a batch, or applied by the sweeper - and the WHERE clause is what makes
sure it is applied at most once, whatever happened in between.

**Pattern: Make replays harmless.** The job decides from the state of the row now, not from what it
was handed.

## 8. Why is the whole batch parsed before anything is written?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | List<Delivery> parsed = parseAll(rows, logs); -->

[WorkItemInboundProcessor.cls:103](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L103)

The processor's first act is to parse the batch, one adapter call per source system, and it writes
nothing until every call has returned. Every outcome, every log row an adapter buffered and every
upsert is collected and written afterwards.

An adapter may call out from `parseInbound`, and Asana's does. Any DML earlier in the transaction
would make that callout fail with `You have uncommitted work pending` - for Asana deliveries only,
with an error that never mentions Asana. One call per system also lets an adapter deduplicate the
tasks a batch mentions and fetch them in bulk.

**Failure mode.** The ordering happened to be safe before Asana, and nothing enforced it, so the rule
is written on the interface, in `CLAUDE.md` and in the handoff. An innocent-looking status update
added at the top of `process` would break Asana and nothing else.

**Pattern: Remote calls before local writes.** The same rule as the outbound push, arrived at from
the other direction.

## 9. Why does only the newest delivery per issue apply?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | Map<String, Delivery> newestByExternalId = new Map<String, Delivery>(); -->

[WorkItemInboundProcessor.cls:116](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L116)

A batch can hold several deliveries about one issue. Only the newest, by the issue's own update
time, is applied; the rest are retired as Ignored with `Ignore_Reason__c = Superseded`, so a bulk
batch can never apply an older state last. The ordering key is the time the issue changed, which
the adapter reads from the issue itself, not the time the event fired, which on a redelivery is
later than both.

Ignored means two things, and the reason field says which: Superseded (a newer delivery won) or Not
Applicable (the adapter had nothing to say about the resource). Retention rules read the value.

**Pattern: Make replays harmless.** Order is recovered from the data, not from arrival.

**Pattern: One flag, one meaning.** Before the reason field, telling the two kinds of Ignored apart
meant string-matching an error message, which breaks the day somebody rewords it.

## 10. How does the timestamp check stop echoes and duplicates?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | change.remoteUpdated <= current.Remote_Last_Modified__c -->

[WorkItemInboundProcessor.cls:180](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L180)

The durable half of loop prevention: a delivery that is not strictly newer than
`Remote_Last_Modified__c` changes nothing and is marked Ignored. That one comparison covers the
echo of our own push, a duplicate and an out-of-order delivery, without needing to know which it
is.

Since build 09 a push stamps `Remote_Last_Modified__c` with the source's own time for what it wrote,
so the late echo of an earlier push is older than the stamp and is retired. Before that, it briefly
reverted the field and marked it Synced - seen on WI-0003, High then none saved 49 seconds apart.
The stamp is the source's clock, so no skew between two clocks enters the comparison.

**Concept.** A Datetime field stores whole seconds, while both sources send milliseconds, so a value
parsed from a payload never equals the one stored from the same payload. Here that is harmless: an
echo in the same second as the stored value counts as newer, and it carries the values already held.

**Pattern: One guard per path.** This is the third of the three loop guards, the one that works
across transactions.

## 11. Why does inbound leave pending fields alone?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | if (pending.contains(SyncField.STATUS)) { -->

[WorkItemInboundProcessor.cls:212](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L212)

A field listed in `Pending_Push_Fields__c` keeps Salesforce's value, and the sync fields are left
alone until nothing is pending. The delivery still applies everything else, and its row says what
was held back.

A delivery that lands between a user's save and the push is genuinely newer than anything held, so
the timestamp check lets it through. A refused change is held the same way, so it keeps showing
Failed with its reason until somebody acts on it.

**Failure mode.** Applying it would undo the edit and mark the record Synced, and the push would then
find the record already agreeing and send nothing - a status change lost, with no error anywhere.

**Pattern: One owner per piece of work.** Until a push settles it, the local edit owns the field,
and inbound does not write over it.

## 12. Why is a field written only when the payload carries it?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | if (String.isNotBlank(change.title)) { -->

[WorkItemInboundProcessor.cls:312](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L312)

A title, type, parent or project is assigned only when the delivery carries one; the dates, the
description and the priority are written, null included, exactly when their carried flag is set.
Most deliveries are status transitions whose payloads carry nothing else.

An issue type that is present with a blank name counts as absent, not as unmapped. The vendor's raw
type word goes into `Source_Type__c`, which is on no DTO and no guest grant, while `Type__c` stays a
restricted picklist - so free text never reaches the public board, and "which types are really in
use" is a GROUP BY rather than a guess.

**Failure mode.** Writing a null through would blank a known title or type on every status-only
delivery.

**Pattern: Absent is not empty.** The processor trusts the adapter's distinction and never writes a
value the delivery did not carry.

## 13. Why are owner and visibility set on creation only?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | Id owner = integrationOwnerId(); -->

[WorkItemInboundProcessor.cls:240](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L240)

When inbound creates a record it sets two things it never sets again. The owner: the processor runs
as Automated Process, so everything it creates would be owned by Automated Process, and guest
sharing rules do not share records owned by that user - measured by reassigning one record, which
took the guest from 2 of 6 public records to 3 of 6. And `Is_Public__c`, inherited from the
record's project, because the project is where that decision lives.

Creation only, both of them: an existing record keeps its owner, and an item unpublished by hand is
not republished by the next delivery. A record whose project resolves to nothing is created private.
If no owner resolves, a log row says so. (The owner is found by profile name, which is brittle; a
named integration user is an open item in the handoff.)

**Concept.** Record ownership drives sharing: a sharing rule grants access to records by who owns
them or by criteria on the record.

**Failure mode.** Either one missing, and every newly synced issue is invisible on the public board,
with no error anywhere.

**Pattern: Know who your code runs as.** The running user leaks into the data it creates, as the
owner, and the owner decides who can see it.

**Pattern: Fail closed.** When the project is unknown, the record defaults to private.

## 14. What happens when an issue moves project?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | a move. Follow it, and log both keys. -->

[WorkItemInboundProcessor.cls:260](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L260)

Three cases, written out in the code: no link yet, assign it; linked to a different key, follow the
move and log both keys; the same key, write nothing. A move whose new key resolves to no project,
or to two, keeps the link it has and logs - nulling a working link over a failed lookup would hide
the record rather than correct it.

**Failure mode.** The rule this replaced, "an existing link is never overridden", protected links
made by hand and froze stale ones in the same breath. On the guest path it failed open: an issue
moved in Jira from a public project to a private one kept pointing at the public one, and the public
board, whose only check of the project's flag is a WHERE clause (tour 5), kept showing it to
anonymous visitors.

**Pattern: Name every case.** One general rule covered three situations and was wrong for one of
them; listing the cases is what exposed it.

## 15. Why are parents linked in a second pass?

<!-- at: force-app/main/default/classes/WorkItemInboundProcessor.cls | private static void resolveParents( -->

[WorkItemInboundProcessor.cls:581](../../force-app/main/default/classes/WorkItemInboundProcessor.cls#L581)

A batch can carry a child and its parent in either order, so links are made after every record in
the batch exists. Resolving during the first pass would miss a parent not yet inserted - and would
do so intermittently, depending on payload order, the worst kind of failure to debug.

No stub records. A parent Salesforce has never seen leaves the link null and writes a log row
naming both sides; a stub would be a titleless card on the board, bought for a link the child's
next delivery makes anyway. The cost is recorded as an open item: nothing back-fills the link when
the parent arrives later. A record naming itself as its own parent is refused, because a cycle of
length one is still a cycle to anything that walks ancestors.

**Pattern: Surface, don't drop.** A reference that cannot be resolved does not fail the delivery or
disappear; it leaves a row saying exactly what is missing.

## 16. What picks up the deliveries nobody finished?

<!-- at: force-app/main/default/classes/WorkItemInboundSweeper.cls | private static final Integer MAX_ATTEMPTS = 3; -->

[WorkItemInboundSweeper.cls:80](../../force-app/main/default/classes/WorkItemInboundSweeper.cls#L80)

Every fifteen minutes, deliveries still Pending after five quiet minutes are handed to the same
queueable again, up to three times, and then retired as Ignored, Not Applicable. Before this class,
"left Pending for the next run" was an intention with no mechanism: Asana's story events (comments,
section changes) and batches that ran out of callouts sat Pending for ever.

The retry count is written before the enqueue, so a job that dies cannot take its own retry budget
with it. The five quiet minutes keep the sweeper off rows the fast path is still working on.
Scheduled Apex cannot call out, so the sweeper enqueues rather than processing - and the job runs as
whoever scheduled it, which is how an Asana callout made from here gets its credential. It is four
cron jobs, at :00, :15, :30 and :45, because Salesforce cron rejects a list in the minutes field.

**Concept.** Scheduled Apex runs as the user who scheduled it, and cannot make callouts.

**Pattern: Bound everything that grows.** A retry has a ceiling, and the query that finds work has a
limit, so the set of Pending rows has a maximum size rather than a trend.

**Pattern: Know who your code runs as.** Schedule it as a user without the Asana grant and every
sweep ends in `We couldn't access the credential(s)`.

<!-- nav:start -->

---

[← 2 · Outbound: a save becomes a push](02-outbound.md) · [All tours](README.md) · [4 · Two adapters behind one interface →](04-adapters.md)

<!-- nav:end -->
