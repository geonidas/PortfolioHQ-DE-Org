# Outbound: a save becomes a push

One edit, followed from the internal board to Jira or Asana. The save commits at once; the push
runs later in a transaction of its own, sends exactly the fields that changed, and writes back how
far it got.

Concepts: before and after triggers, transaction scope and statics, Queueable Apex, governor limits
on callouts, Named Credentials, row locks, `with sharing` and `without sharing`.

<!-- stops:start -->

1. [Why doesn't the board call the sync service?](#1-why-doesnt-the-board-call-the-sync-service)
2. [Why does the trigger have two halves?](#2-why-does-the-trigger-have-two-halves)
3. [What counts as a change?](#3-what-counts-as-a-change)
4. [How does the push know what to send?](#4-how-does-the-push-know-what-to-send)
5. [What stops an inbound change from being pushed straight back?](#5-what-stops-an-inbound-change-from-being-pushed-straight-back)
6. [How is a retry requested?](#6-how-is-a-retry-requested)
7. [Why a queueable, and why chunks of 25?](#7-why-a-queueable-and-why-chunks-of-25)
8. [Which fields does a job send when two saves overlap?](#8-which-fields-does-a-job-send-when-two-saves-overlap)
9. [Why does every callout come before any write?](#9-why-does-every-callout-come-before-any-write)
10. [Why do adapters buffer their log rows?](#10-why-do-adapters-buffer-their-log-rows)
11. [Why can a Jira push take four callouts?](#11-why-can-a-jira-push-take-four-callouts)
12. [How does a result say that half of it worked?](#12-how-does-a-result-say-that-half-of-it-worked)
13. [Why re-read the row under a lock before writing back?](#13-why-re-read-the-row-under-a-lock-before-writing-back)

<!-- stops:end -->

## 1. Why doesn't the board call the sync service?

<!-- at: force-app/main/default/classes/WorkItemBoardController.cls | Writes Status__c and nothing else. WorkItemTrigger does the rest -->

[WorkItemBoardController.cls:135](../../force-app/main/default/classes/WorkItemBoardController.cls#L135)

`changeStatus` writes `Status__c`, in user mode, and returns. The trigger stages and enqueues the
push, so calling `WorkItemSyncService` here as well would either throw - a callout cannot follow
DML in the same transaction - or push twice. `saveDetails` and `retryPush` follow the same rule.

The method counts queued jobs across its update, as direct evidence that the trigger fired rather
than an assumption that it did, and its message says what is true: saved in Salesforce, with the
source's update "running in the background". The record reads Pending.

**Concept.** `AccessLevel.USER_MODE` applies the running user's object permissions, field
permissions and sharing to a query or DML statement, which Apex otherwise skips.

**Failure mode.** Calling the service from the controller is the obvious shortcut, and it fails
either loudly (`You have uncommitted work pending`) or silently (two pushes of one change).

**Pattern: Attach the side effect to the change.** Because the push hangs off the record change,
the record page, the REST API and a data load push exactly the way the board does, and no caller
can skip it or double it.

**Pattern: Honest state.** The board never claims the source has changed; it says a push is under
way.

## 2. Why does the trigger have two halves?

<!-- at: force-app/main/default/triggers/WorkItemTrigger.trigger | trigger WorkItemTrigger on Work_Item__c( -->

[WorkItemTrigger.trigger:9](../../force-app/main/default/triggers/WorkItemTrigger.trigger#L9)

Two jobs on three events. Before update, `stageForPush` records which pushable fields changed in
`Pending_Push_Fields__c` and marks the record Pending. After update, `pushChanges` enqueues a push
that owns those fields. Before insert and before update also refuse a start date the record's
source cannot hold.

**Concept.** A before trigger edits the rows being saved in place, at no DML cost. An after trigger
runs once they are saved and is where follow-on work is queued. Apex refuses a callout from trigger
context, so the push itself has to run asynchronously.

**Failure mode.** The push sends exactly what was staged. Without the staging half, every push finds
nothing to send and reports success while doing nothing - the trigger's own header says so, because
nothing else would.

**Pattern: Stage, then act.** The edit and the record of what must be pushed commit together, in one
transaction. The slow, remote part reads that record later.

**Pattern: The server holds the rule.** The board hides the start date editor for a source without
start dates; the trigger refuses one on every path, the record page and the API included.

## 3. What counts as a change?

<!-- at: force-app/main/default/classes/SyncFields.cls | public static Set<SyncField> changedBetween( -->

[SyncFields.cls:23](../../force-app/main/default/classes/SyncFields.cls#L23)

The one definition of a pushable change: status (unless it moved to Unspecified), title, start date,
due date and priority - and nothing at all for a record with no `External_Id__c`, which has no
remote record to update. Both halves of the trigger call it, so they cannot disagree.

The title is compared with `equals`, because `==` on Apex strings ignores case. The priority is a
picklist whose values differ by more than case, so `==` is right there.

**Concept.** Apex's `==` on two strings is case-insensitive.

**Failure mode.** With `==`, retitling "Deep work" to "Deep Work" is no change at all and never
reaches the source. With two copies of the rule, the before half stages a field the after half
never pushes.

**Pattern: One home for each fact.** None of the sync's own write-back fields - `Sync_Status__c`,
`Last_Synced__c`, `Pending_Push_Fields__c`, `Sync_Error__c` - is in this list, and that is what
stops a write-back from pushing again. One list decides it.

## 4. How does the push know what to send?

<!-- at: force-app/main/default/classes/WorkItemTriggerHandler.cls | // Added to, never replaced -->

[WorkItemTriggerHandler.cls:100](../../force-app/main/default/classes/WorkItemTriggerHandler.cls#L100)

The fields this save changed are merged into what is already pending, never written over it, and
the last failure's reason is cleared because a new attempt is under way. If the caller set
`Sync_Status__c` in the same update, their explicit value wins over the inferred Pending.

Sending only the changed fields matters on the other side too. Sending an unchanged due date
alongside a new title would overwrite a due date somebody had just changed in Jira.

**Failure mode.** Replacing the set instead of adding to it means a second edit, saved before the
first push lands, silently erases the first edit's fields. Pushing the whole record silently undoes
edits made in the source.

**Pattern: Deltas, not snapshots.** What travels is the change, and what is stored is the union of
changes not yet confirmed.

## 5. What stops an inbound change from being pushed straight back?

<!-- at: force-app/main/default/classes/SyncContext.cls | private static Integer suppressionDepth = 0; -->

[SyncContext.cls:12](../../force-app/main/default/classes/SyncContext.cls#L12)

A transaction-scoped switch. Inbound processing suppresses outbound around its upsert, so a value
that arrives from the source is never sent back to it. The trigger checks the switch before it
enqueues anything, because a static does not survive into an async job - checking it inside the
queueable would be reading a fresh, empty context. It is a depth counter rather than a boolean, so
an inner resume cannot lift an outer suppression, and the sync paths resume in a `finally`.

Loop prevention is three mechanisms, and each stops a different path. Suppression stops inbound's
own DML. The field-delta check (the previous two stops) stops the sync's own write-back, and makes
the echo of our own push harmless: it carries our values, so it changes nothing. The timestamp
comparison in tour 3 retires stale and duplicate deliveries.

**Concept.** An Apex static lives for one transaction and no longer.

**Failure mode.** Drop any one mechanism and its path loops. The symptom is `Integration_Log__c`
climbing three rows at a time after a single status change.

**Pattern: One guard per path.** Each guard is chosen for the path it closes, and the handler's
header names all of them, so removing one is never mistaken for removing a duplicate.

## 6. How is a retry requested?

<!-- at: force-app/main/default/classes/WorkItemTriggerHandler.cls | private static Boolean isRetry(Work_Item__c item, Work_Item__c prior) { -->

[WorkItemTriggerHandler.cls:69](../../force-app/main/default/classes/WorkItemTriggerHandler.cls#L69)

A retry is a save: a record with a remote id and something still pending, moved from Failed to
Pending. The trigger clears `Sync_Error__c` and queues a push, and because the record was Failed -
the job that was refused has finished, so nothing holds its fields - the new job takes over what
was refused. The board's Retry button calls `retryPush`, which makes exactly that save and nothing
else.

**Failure mode.** A separate "retry" method that called the sync service would bring back both
problems from the first stop. Setting Pending by hand on a Failed record, for any other reason,
sends it again - which the handoff warns about.

**Pattern: Attach the side effect to the change.** There is no second mechanism for "send again",
so the record page, an API client and a data load all retry the same way. The sync's own writes run
suppressed, so they never count as one.

## 7. Why a queueable, and why chunks of 25?

<!-- at: force-app/main/default/classes/WorkItemSyncQueueable.cls | public without sharing class WorkItemSyncQueueable implements Queueable, Database.AllowsCallouts { -->

[WorkItemSyncQueueable.cls:22](../../force-app/main/default/classes/WorkItemSyncQueueable.cls#L22)

The async half of the push. A transaction may make at most 100 callouts in 120 seconds, and a Jira
push can take four (an edit, a two-step transition and a read of the issue's update time), so a job
takes 25 items, pushes them, and chains the rest into a new job with fresh limits. Before each item,
`WorkItemSyncService.hasBudget` checks both the callouts left and the time used, and stops at 90
seconds rather than risk being killed mid-chunk and losing the buffered logs. The chunk was 50, then
33, as the callouts per item grew.

The job carries the whole outstanding list, not a pre-cut slice, so anything a chunk did not reach
is still in the list for the next link. Ids the query no longer returns are dropped (the record was
deleted), and a job that made no progress stops instead of chaining for ever.

`without sharing` states what the job is: a system process finishing a push that a user was allowed
to make. Sharing was checked when they saved.

**Concept.** Queueable Apex runs in its own transaction with its own governor limits, may call out
when it implements `Database.AllowsCallouts`, and may enqueue its successor.

**Pattern: Design to the limit.** The chunk size is derived from the callout limit, and the time
limit is checked as the work runs, because at current latency the count binds first but need not
always.

**Pattern: Bound everything that grows.** A chain that makes no progress ends.

## 8. Which fields does a job send when two saves overlap?

<!-- at: force-app/main/default/classes/WorkItemSyncQueueable.cls | if (staged != null && otherPushesInFlight(context)) { -->

[WorkItemSyncQueueable.cls:68](../../force-app/main/default/classes/WorkItemSyncQueueable.cls#L68)

Two saves a few seconds apart queue two jobs. Each owns the fields its own save staged and, while
another push job is queued or running, sends only those that are still pending. With no other push
in flight, nothing else can be holding a field, so the job sends everything pending - which is how a
field whose job died after calling out still goes with the next push. The check is one coarse
`AsyncApexJob` count.

The same field saved twice is owned by both jobs, deliberately: the second save may carry a newer
value.

**Concept.** Queued jobs run concurrently, and nothing orders them.

**Failure mode.** Before build 08 step 7, each job sent everything pending. When the second started
before the first had written back, it sent the first save's fields again - seen live on WI-0015,
one status pushed twice.

**Pattern: One owner per piece of work.** Each field belongs to the job its save queued, with a
fallback for the case where no owner is left.

## 9. Why does every callout come before any write?

<!-- at: force-app/main/default/classes/WorkItemSyncService.cls | // Callouts are finished. DML from here down. -->

[WorkItemSyncService.cls:141](../../force-app/main/default/classes/WorkItemSyncService.cls#L141)

The loop above this line calls out for each item and keeps every result and log row in memory.
Everything below it writes: the work items first, then the log rows. An adapter that throws is
caught per item, so one bad record cannot strand the others and their buffered logs.

Items are written before logs, and logs are written best-effort (`Database.insert(logs, false)`
inside a `try`), because logging is observability: losing it must never fail a sync that already
succeeded remotely.

**Concept.** Once a transaction holds uncommitted DML, Apex refuses any further callout with
`You have uncommitted work pending`.

**Failure mode.** A log row inserted after the first item's callout works for that item and throws
on the second.

**Pattern: Remote calls before local writes.** Every network call a unit of work needs happens
before its first write, and anything worth recording about those calls waits in memory.

## 10. Why do adapters buffer their log rows?

<!-- at: force-app/main/default/classes/JiraAdapter.cls | Issues one callout and buffers exactly one Integration_Log__c row for it -->

[JiraAdapter.cls:971](../../force-app/main/default/classes/JiraAdapter.cls#L971)

Every callout gets exactly one `Integration_Log__c` row - method, endpoint, status, duration,
truncated request and response - whether it succeeded or threw. The row goes into the adapter's own
buffer, and the caller drains it with `drainLogs` and inserts once, after the last callout. Each
value is cut to its field length first, because one over-long body fails the whole insert, and a
log row that fails to write is a log row nobody reads.

**Concept.** A Named Credential holds an endpoint and its authentication, so the request says
`callout:Jira_Classic` and no token appears in code, in a log row or in source control.

**Pattern: Remote calls before local writes.** The rule from the previous stop, pushed down into the
adapter, where the callouts actually happen.

## 11. Why can a Jira push take four callouts?

<!-- at: force-app/main/default/classes/JiraAdapter.cls | public SyncResult push(Work_Item__c item, Set<SyncField> changed) { -->

[JiraAdapter.cls:555](../../force-app/main/default/classes/JiraAdapter.cls#L555)

Field edits go first, as one PUT carrying only the changed fields: a cleared date as an explicit
null, the priority by id. Then the status. Jira will not accept a target status, so the adapter
lists the transitions reachable from where the issue is and posts the one whose destination
matches; transition ids belong to a workflow and are never hardcoded. When none matches, one read
checks whether the issue is already there, which counts as done - that is what lets a refused move
be undone by moving the card back. Finally, if anything was written, a read of `?fields=updated`
gives the write-back the source's own timestamp to stamp (tour 3 shows why).

Edits go before the transition because some workflows make an issue read-only once it is Done.
Each part is attempted on its own merits, and the result says which ones landed.

**Failure mode.** Matching a transition by its own name ("Start Progress") rather than by where it
lands, or hardcoding its id, works on one workflow and breaks on the next.

**Pattern: Deltas, not snapshots.** The PUT names only the fields that changed, so nothing the
source holds is overwritten with a value Salesforce merely happened to have.

## 12. How does a result say that half of it worked?

<!-- at: force-app/main/default/classes/SyncResult.cls | public Set<SyncField> confirmedFields { get; set; } -->

[SyncResult.cls:35](../../force-app/main/default/classes/SyncResult.cls#L35)

A push returns an `Outcome` and the set of fields the source accepted. `confirmedFields` is set on a
failure too, because a push can land its title and have its transition refused: forgetting the half
that landed would push it again for nothing, and clearing the half that did not would mark a refused
change as synced.

The `Outcome` enum keeps "the source said no" (`NO_TRANSITION_AVAILABLE`, `BAD_REQUEST`: a retry
will not help) apart from "the source broke" (`UNAUTHORIZED`, `RATE_LIMITED`, `REMOTE_ERROR`,
`CALLOUT_FAILED`) in the type system, so callers branch on a value and the message is only for
people. It is written `SyncResult.Outcome.SUCCESS` inside the class because Apex identifiers are
case-insensitive, and the field `outcome` would otherwise shadow the type `Outcome`.

**Pattern: Answer for the caller's next move.** Whether to retry is the question every caller has,
so the result answers it in a type rather than a sentence.

**Pattern: Honest state.** Partial success is recorded as partial, field by field.

## 13. Why re-read the row under a lock before writing back?

<!-- at: force-app/main/default/classes/WorkItemSyncService.cls | private static List<Work_Item__c> writeBack(List<SyncResult> results) { -->

[WorkItemSyncService.cls:217](../../force-app/main/default/classes/WorkItemSyncService.cls#L217)

After the callouts, the job re-reads its rows `FOR UPDATE` and works out each record's sync fields
against what is stored now, removing only the confirmed fields from `Pending_Push_Fields__c`. Three
outcomes, laid out in the method's comment: everything confirmed and nothing else waiting is
Synced, and `Last_Synced__c` moves; confirmed but with a newer edit waiting stays Pending, because
that edit's job is queued; refused is Failed, with the reason in `Sync_Error__c` and the refused
fields still pending. `Remote_Last_Modified__c` only ever moves forward.

**Concept.** `SELECT ... FOR UPDATE` locks the rows until the transaction ends, so a save arriving
during the write waits for it rather than racing it.

**Failure mode.** The user may edit while a push is in flight. Writing back the set this job started
with would erase that edit's staged fields; its own job would then find nothing to send, and the
record would read Synced with the edit never sent.

**Pattern: Deltas, not snapshots.** The write-back subtracts what was confirmed from what is there
now, instead of writing a copy of what was there before.

**Pattern: Honest state.** `Last_Synced__c` moves only on success, so it keeps meaning "the last
time both sides agreed" rather than "the last time we tried".

<!-- nav:start -->

---

[← 1 · The shape of the system](01-shape.md) · [All tours](README.md) · [3 · Inbound: a webhook becomes a record →](03-inbound.md)

<!-- nav:end -->
