# The shape of the system

The few types everything else is built on: one record per piece of work, keyed on the source
system's own id, and an interface that keeps each source's vocabulary out of the rest of the code.

Concepts: custom objects and External ID fields, picklists, validation rules, Apex interfaces.

<!-- stops:start -->

1. [What are the moving parts?](#1-what-are-the-moving-parts)
2. [Why is every external id stored as `jira:10023`?](#2-why-is-every-external-id-stored-as-jira10023)
3. [Why does a picklist value never appear as a literal?](#3-why-does-a-picklist-value-never-appear-as-a-literal)
4. [Why can a record with an unmapped status never read Synced?](#4-why-can-a-record-with-an-unmapped-status-never-read-synced)
5. [What does the rest of the code ask of Jira or Asana?](#5-what-does-the-rest-of-the-code-ask-of-jira-or-asana)
6. [Where is a vendor allowed to be named?](#6-where-is-a-vendor-allowed-to-be-named)
7. [What does an inbound change look like once the vendor is gone?](#7-what-does-an-inbound-change-look-like-once-the-vendor-is-gone)

<!-- stops:end -->

## 1. What are the moving parts?

Portfolio HQ keeps work items in a Salesforce org in two-way sync with Jira and Asana, shows them on
an internal Kanban board that edits and pushes, and publishes a read-only board of the public ones
to anyone with the link. Three paths carry all of it:

```text
Outbound  board save -> Work_Item__c -> WorkItemTrigger -> WorkItemSyncQueueable
          -> WorkItemSyncService -> IWorkItemAdapter -> Jira / Asana REST

Inbound   Jira / Asana webhook -> REST resource (site guest) -> Webhook_Event__c
          -> Webhook_Event_Received__e -> WorkItemInboundQueueable
          -> WorkItemInboundProcessor -> IWorkItemAdapter.parseInbound -> upsert Work_Item__c

Boards    workItemBoard -> WorkItemBoardController           (internal: read and write)
          publicWorkItemBoard -> PublicBoardController        (guest: read only)
          both share boardCard, boardModel, boardLayout ...   (import no Apex)
```

The records that matter: `Work_Item__c` (the work, with its sync state), `Project__c` (which
carries `Is_Public__c`), `Webhook_Event__c` (one row per inbound delivery), `Integration_Log__c`
(one row per callout or processing problem), and two custom metadata types that hold configuration:
`Field_Mapping__mdt` and `Board_Source__mdt`.

This tour covers the shared types. Tour 2 follows a save out to a source system, tour 3 follows a
webhook in, tour 4 compares the two adapters, tour 5 is the public boundary, tour 6 the two boards,
and tour 7 how all of it is tested and operated.

## 2. Why is every external id stored as `jira:10023`?

<!-- at: force-app/main/default/classes/ExternalIdUtil.cls | public static String qualify(String systemNamespace, String rawId) { -->

[ExternalIdUtil.cls:19](../../force-app/main/default/classes/ExternalIdUtil.cls#L19)

`External_Id__c` is the key every inbound write upserts on, and it is unique. Uniqueness is per
field, not per system, so a Jira issue id and an Asana gid that happened to share digits would
collide. The id is therefore stored qualified with its system - `jira:10023`,
`asana:1210000000000077` - and `rawIdOf` strips the prefix before the id goes into a REST path. The
adapter factory routes on the same prefix.

The raw part is always the vendor's permanent id. Never Jira's human key (`DOPP-15`), which changes
when an issue moves project; `External_Key__c` holds that, for display only.

**Concept.** An External ID field is indexed and can be the key of an upsert:
`Database.upsert(rows, Work_Item__c.External_Id__c, false)` inserts or updates by that value, so
the inbound path never looks up Salesforce ids first.

**Failure mode.** Unqualified ids work until the second system arrives. Then an Asana task whose gid
equals a Jira issue id upserts onto the Jira record.

**Pattern: Key on what doesn't change.** The key is the vendor's permanent id, qualified by the
system it belongs to, and `split` refuses a blank or unqualified value rather than guessing.

## 3. Why does a picklist value never appear as a literal?

<!-- at: force-app/main/default/classes/WorkItemStatus.cls | public static final String UNSPECIFIED = 'Unspecified'; -->

[WorkItemStatus.cls:11](../../force-app/main/default/classes/WorkItemStatus.cls#L11)

Every picklist API name the code compares against lives in a small constants class:
`WorkItemStatus`, `SyncStatus`, `WorkItemType`, `ExternalSystem`, `DeliveryStatus`,
`LogDirection`, `IgnoreReason`.

**Concept.** A picklist field stores its value as a string. Nothing links Apex to the picklist's
metadata at compile time, so `item.Status__c == 'Todo'` compiles and is simply false for every
record.

**Failure mode.** A misspelt literal at a call site is a silent no-op: a branch that never runs, a
filter that matches nothing. A misspelt constant name does not compile.

**Pattern: One home for each fact.** Each string exists once, beside a comment saying what it
means - `UNSPECIFIED` is the landing value for a remote status with no mapping, and is never
pushed - and every other class names the constant.

## 4. Why can a record with an unmapped status never read Synced?

<!-- at: force-app/main/default/objects/Work_Item__c/validationRules/Sync_Status_Requires_Known_Status.validationRule-meta.xml | <errorConditionFormula>AND( -->

[Sync_Status_Requires_Known_Status.validationRule-meta.xml:6](../../force-app/main/default/objects/Work_Item__c/validationRules/Sync_Status_Requires_Known_Status.validationRule-meta.xml#L6)

`Status__c = Unspecified` means the source reported a status no mapping covers. `Sync_Status__c =
Synced` claims that Salesforce and the source agree. This validation rule makes the two together
unsaveable, so inbound leaves such a record Pending, and outbound never pushes Unspecified
(`SyncFields.changedBetween` ignores it and both adapters refuse it as a target).

**Concept.** A validation rule runs on every save - the record page, the API, Apex, a data load -
and rejects the row when its formula is true.

**Failure mode.** Without it, a record could show a green Synced while its status is a placeholder,
and nobody would be prompted to add the missing mapping.

**Pattern: Honest state.** Synced is a claim about the world, so it is only allowed where it can be
true.

**Pattern: The server holds the rule.** The rule sits where every write passes, not in one of the
code paths that happens to write the field.

## 5. What does the rest of the code ask of Jira or Asana?

<!-- at: force-app/main/default/classes/IWorkItemAdapter.cls | public interface IWorkItemAdapter { -->

[IWorkItemAdapter.cls:8](../../force-app/main/default/classes/IWorkItemAdapter.cls#L8)

Six methods, covering both directions: `push(item, fields)`, `fetchAvailableTransitions`,
`parseInbound(batch)`, `normalizeStatus`, `normalizeType` and `drainLogs`. Nothing in the
signatures, or in the types they exchange (`SyncField`, `SyncResult`, `InboundChange`,
`TransitionOption`), is vendor vocabulary: `SyncField.TITLE` is Jira's summary and Asana's name.

The contracts are written on the interface, because they are what callers rely on: `push` never
throws for a business outcome, `parseInbound` never throws for an unusable payload and takes a
whole batch, and no DML may happen in the transaction before `parseInbound` is called (tour 3
explains why).

**Concept.** Ports and adapters: the core defines the interface it needs, and each external
system gets a class that implements it.

**Failure mode.** Until the refactor after build 06, the inbound processor parsed Jira's payload
itself. Had it stayed that way, Asana would have needed a second processor, with its own copy of
every rule about applying a change.

**Pattern: Vendor at the edge.** Adding Asana in build 07 was a new class and one line in the
factory. The processor, the sync service and both boards did not change.

## 6. Where is a vendor allowed to be named?

<!-- at: force-app/main/default/classes/WorkItemAdapterFactory.cls | public static IWorkItemAdapter forSystem(String systemNamespace) { -->

[WorkItemAdapterFactory.cls:35](../../force-app/main/default/classes/WorkItemAdapterFactory.cls#L35)

Here, in the adapters themselves, in the two webhook endpoints and in the `ExternalSystem`
constants, because something has to construct the concrete class and something has to answer each
vendor's HTTP. The factory routes on
the external id's namespace, which is what actually decides which API an id is valid against,
rather than on `External_System__c`, which stays descriptive.

`injected` lets a test replace the adapter when the thing under test is the sync service, not the
wire.

**Failure mode.** Without a single constructor, vendor checks spread into every caller, and each new
system means editing each of them.

**Pattern: Vendor at the edge.** A third system is a class and a line here.

**Pattern: Control what the test reads.** The seam is one `@TestVisible` static, so a service test
never depends on HTTP at all.

## 7. What does an inbound change look like once the vendor is gone?

<!-- at: force-app/main/default/classes/InboundChange.cls | public Boolean carriesDueDate { get; private set; } -->

[InboundChange.cls:86](../../force-app/main/default/classes/InboundChange.cls#L86)

`InboundChange` is what an adapter hands the processor: one change to one work item, in
Salesforce's terms. For its optional fields the rule is that null means "this delivery did not
carry it", never "the source holds nothing". Four fields can genuinely be emptied in the source -
the start date, due date, description and priority - so each carries a flag beside its value, and
the value can only be set through `carry*()`, which sets the flag too. The setters are private, so
there is no way to set a value without saying it was carried.

Each change also names the delivery it came from (`sourceEventId`): an adapter may return fewer
changes than it was given, so results are matched by id, never by position.

**Failure mode.** With one convention for both meanings, either every status-only delivery blanks
the title, or a due date removed in Jira never clears in Salesforce.

**Pattern: Absent is not empty.** Two states that look alike in a payload - key missing, and key
present with no value - get two representations in the type.

<!-- nav:start -->

---

[All tours](README.md) · [2 · Outbound: a save becomes a push →](02-outbound.md)

<!-- nav:end -->
