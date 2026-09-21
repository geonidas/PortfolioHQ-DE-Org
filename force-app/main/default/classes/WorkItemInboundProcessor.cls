/**
 * Applies verified inbound deliveries to Work_Item__c, in the platform event subscriber's
 * transaction.
 *
 * Vendor-neutral. Each delivery names its source system; the matching adapter turns the raw
 * payload into an InboundChange, and everything from there on is in Work_Item__c vocabulary.
 * Adding Asana means an Asana adapter with its own parseInbound, not an edit here. Until the
 * refactor pass after build 06 this class was JiraWebhookProcessor and parsed Jira's payload
 * itself; older docs use that name.
 *
 * Runs as the Automated Process user, not the guest who received the delivery - that user switch
 * is the entire reason the platform event exists. This is also the first point at which the
 * payload is deserialised: by now the signature has proved where it came from.
 *
 * Loop prevention lives here, in two parts. The timestamp comparison is the durable one and
 * decides whether a change is applied at all. The SyncContext suppression is narrower - it only
 * covers this transaction's DML, stopping the outbound trigger from pushing straight back.
 */
public with sharing class WorkItemInboundProcessor {
  private static final Integer EVENT_ERROR_MAX = Webhook_Event__c.Error_Message__c.getDescribe()
    .getLength();
  private static final Integer LOG_ERROR_MAX = Integration_Log__c.Error_Message__c.getDescribe()
    .getLength();
  private static final Integer EVENT_TYPE_MAX = Webhook_Event__c.Event_Type__c.getDescribe()
    .getLength();
  private static final Integer EXTERNAL_ID_MAX = Webhook_Event__c.External_Id__c.getDescribe()
    .getLength();
  private static final Integer SOURCE_TYPE_MAX = Work_Item__c.Source_Type__c.getDescribe()
    .getLength();

  /**
   * One delivery, parsed, plus what this class learns about it while applying it.
   *
   * The field is sourceSystem, not externalSystem: Apex identifiers are case-insensitive, so a
   * member or parameter named externalSystem shadows the ExternalSystem class and every call on
   * it fails to compile. Found by the deploy, as the handoff warned it would be.
   */
  private class Delivery {
    Id eventId;
    String sourceSystem; // the picklist value the delivery carried, e.g. Jira
    InboundChange change; // null when the adapter could not be resolved
    String failure; // non-null means the delivery cannot be applied
    Boolean ownerUnresolved = false;
    // The project link's story, already worded, or null when there is nothing to report. Built
    // at decision time rather than after the upsert because that is where the prior link is
    // still in hand; only the record id is missing then, and inboundLog supplies it.
    String projectNote;
    Id workItemId; // filled from the upsert result, for the second pass
  }

  /**
   * Subscriber entry point. Hands the batch to a queueable and does nothing else.
   *
   * This runs in a TRIGGER - the subscriber on Webhook_Event_Received__e - and Apex refuses a
   * callout made from one. An adapter is allowed to call out from parseInbound, and AsanaAdapter
   * must, so applying a delivery here would fail with "Callout from triggers are currently not
   * supported" for Asana and work fine for Jira. It did exactly that on the first live delivery.
   *
   * Enqueuing instead is the same move the outbound path makes: WorkItemTriggerHandler does not
   * call out either, it enqueues WorkItemSyncQueueable. Every system goes async, not just the
   * ones that hydrate, because choosing per system would mean this class knowing which adapters
   * call out.
   */
  public static void handle(List<Webhook_Event_Received__e> events) {
    Set<Id> eventIds = new Set<Id>();
    for (Webhook_Event_Received__e event : events) {
      if (String.isNotBlank(event.Webhook_Event_Id__c)) {
        eventIds.add((Id) event.Webhook_Event_Id__c);
      }
    }
    if (eventIds.isEmpty()) {
      return;
    }
    // Queueables cannot be enqueued from a test's platform event delivery at stopTest, and a
    // failure to enqueue would silently strand every delivery. The processor is still callable
    // directly, which is how the existing tests drive it.
    System.enqueueJob(new WorkItemInboundQueueable(eventIds));
  }

  /**
   * Bulk-safe. Callable directly so tests can exercise processing without standing up the
   * event bus.
   *
   * @param rows deliveries carrying at least Id, Source_System__c and Raw_Payload__c
   */
  public static void process(List<Webhook_Event__c> rows) {
    if (rows == null || rows.isEmpty()) {
      return;
    }

    Map<Id, Webhook_Event__c> updates = new Map<Id, Webhook_Event__c>();

    // Rows the adapters buffered while reading the batch, and everything this class adds
    // later. Collected at method scope and written once, at the end, after the upsert: a
    // parseInbound that called out must not be followed by DML until every callout is done.
    List<Integration_Log__c> logs = new List<Integration_Log__c>();

    // One adapter call per source system, before any DML in this transaction. See the rule on
    // IWorkItemAdapter.parseInbound - an adapter is allowed to call out from there.
    List<Delivery> parsed = parseAll(rows, logs);

    for (Delivery delivery : parsed) {
      if (delivery.failure != null) {
        updates.put(
          delivery.eventId,
          terminal(delivery, DeliveryStatus.FAILED, delivery.failure)
        );
      }
    }

    // Several deliveries in one batch can concern one issue. Keep only the newest per issue
    // and retire the rest as Ignored, so a bulk batch cannot apply an older state last.
    Map<String, Delivery> newestByExternalId = new Map<String, Delivery>();
    for (Delivery delivery : parsed) {
      // No failure and no change means the adapter returned nothing for this delivery - it
      // ran out of callouts, or it had nothing to say about the resource. The row is left
      // exactly as it was found, still Pending, for the next run to pick up.
      if (delivery.failure != null || delivery.change == null) {
        continue;
      }
      String externalId = delivery.change.externalId;
      Delivery held = newestByExternalId.get(externalId);
      if (
        held == null ||
        delivery.change.remoteUpdated > held.change.remoteUpdated
      ) {
        if (held != null) {
          updates.put(held.eventId, superseded(held));
        }
        newestByExternalId.put(externalId, delivery);
      } else {
        updates.put(delivery.eventId, superseded(delivery));
      }
    }
    if (newestByExternalId.isEmpty()) {
      writeLogs(logs);
      commitEvents(updates.values());
      return;
    }

    Map<String, Work_Item__c> existing = new Map<String, Work_Item__c>();
    for (Work_Item__c item : [
      SELECT
        Id,
        External_Id__c,
        Status__c,
        Sync_Status__c,
        Project__c,
        // The key, not just the id: a delivery that moves an issue between projects has to
        // name the project it is leaving, and this costs no extra query.
        Project__r.External_Project_Key__c,
        Remote_Last_Modified__c
      FROM Work_Item__c
      WHERE External_Id__c IN :newestByExternalId.keySet()
    ]) {
      existing.put(item.External_Id__c, item);
    }

    Map<String, Project__c> projectByLookup = resolveProjects(
      newestByExternalId.values()
    );

    List<Work_Item__c> toUpsert = new List<Work_Item__c>();
    List<Delivery> applied = new List<Delivery>();

    for (Delivery delivery : newestByExternalId.values()) {
      InboundChange change = delivery.change;
      Work_Item__c current = existing.get(change.externalId);

      // Loop prevention, durable half. A delivery that is not strictly newer than what we
      // already hold changes nothing - that covers the echo of our own push, a duplicate
      // delivery, and an out-of-order one, without needing to know which it was.
      if (
        current != null &&
        current.Remote_Last_Modified__c != null &&
        change.remoteUpdated <= current.Remote_Last_Modified__c
      ) {
        updates.put(
          delivery.eventId,
          terminal(
            delivery,
            DeliveryStatus.IGNORED,
            'Payload is not newer than Remote_Last_Modified__c; nothing applied.'
          )
        );
        continue;
      }

      Work_Item__c item = new Work_Item__c(
        External_Id__c = change.externalId,
        External_Key__c = change.externalKey,
        External_System__c = delivery.sourceSystem,
        Status__c = change.normalizedStatus,
        Remote_Last_Modified__c = change.remoteUpdated,
        Last_Synced__c = System.now(),
        // Synced is illegal alongside an Unspecified status - see the
        // Sync_Status_Requires_Known_Status validation rule. An unmapped remote status
        // therefore stays Pending, which is also honest: we have not reconciled it.
        Sync_Status__c = change.normalizedStatus == WorkItemStatus.UNSPECIFIED
          ? SyncStatus.PENDING
          : SyncStatus.SYNCED
      );

      // Only on creation. This subscriber runs as the Automated Process user, so anything it
      // inserts is owned by Automated Process - and guest sharing rules do not share records
      // owned by that user, measured directly: reassigning one record took the guest from 2 of
      // 6 public records to 3 of 6, instantly. Without this every newly synced issue would be
      // invisible on the public board, with no error to notice.
      //
      // Deliberately not set on update, so an existing record keeps whatever owner it has.
      if (current == null) {
        Id owner = integrationOwnerId();
        if (owner != null) {
          item.OwnerId = owner;
        } else {
          // Logged after the upsert, once there is a record id to point the row at. The
          // record still syncs; it is simply owned by Automated Process and invisible to
          // guests, and the log row is what stops that being silent.
          delivery.ownerUnresolved = true;
        }
      }

      // The project link, in the three cases the refactor pass after build 06 conflated into
      // one rule ("an existing link is never overridden"). That rule protected links made by
      // hand and froze stale ones in the same breath, and on the guest path it failed open:
      // an issue moved in Jira from a public project to a private one carried the new key,
      // the key was ignored, the record kept pointing at the public project, and the public
      // board - which gates on the parent project's Is_Public__c - kept rendering it to
      // anonymous visitors after its remote home had become private.
      //
      //   no link           -> assign. The back-fill path, unchanged.
      //   link, other key   -> a move. Follow it, and log both keys.
      //   link, same key    -> nothing to do, and nothing written.
      //
      // A move whose new key resolves to nothing, or to more than one project, keeps the link
      // it has. Nulling a working link because a lookup failed would trade a naming problem
      // for an invisible record, which is the failure this whole block exists to prevent.
      Project__c resolvedProject = null;
      if (change.projectKey != null) {
        resolvedProject = projectByLookup.get(
          lookupKey(delivery.sourceSystem, change.projectKey)
        );
        Id resolved = resolvedProject == null ? null : resolvedProject.Id;
        Id held = current == null ? null : current.Project__c;
        if (held == null) {
          if (resolved != null) {
            item.Project__c = resolved;
          } else {
            delivery.projectNote = unlinkedNote(delivery);
          }
        } else if (resolved == null) {
          delivery.projectNote = unresolvedMoveNote(delivery, current);
        } else if (resolved != held) {
          item.Project__c = resolved;
          delivery.projectNote = movedNote(delivery, current);
        }
      }

      // Public visibility is inherited from the project, on creation only.
      //
      // The field defaults to false, so before this every newly synced item landed invisible
      // and stayed that way until somebody ticked the box by hand - one silent manual step
      // between a real task and the board this project exists to publish. Nothing errors when
      // it is missed; the item simply never appears.
      //
      // Inherited rather than defaulted true, because the project flag is where the decision
      // already lives: work synced into a private project must not become public just because
      // it arrived over a webhook. The two flags together are what
      // PublicWorkItemSelector's WHERE clause tests, so this makes the common case agree with
      // the gate instead of fighting it.
      //
      // Creation only, and that is the important half. An item unpublished by hand must stay
      // unpublished - a later status change from the remote system is not a request to put it
      // back on the board, and writing this on update would silently overrule that decision
      // every time the source system touched the record.
      if (current == null) {
        item.Is_Public__c =
          resolvedProject != null &&
          resolvedProject.Is_Public__c == true;
      }

      // Only when the payload actually carried one. Assigning a null would blank a title
      // we already hold, and a delivery that omits the summary is not a retitling.
      if (String.isNotBlank(change.title)) {
        item.Title__c = change.title;
      }

      // The same rule, for the same reason. Most deliveries here are status transitions, whose
      // payloads carry no issuetype at all; assigning a null would blank a known type on every
      // one of them. Unspecified, by contrast, is a real value the payload asked for.
      if (String.isNotBlank(change.normalizedType)) {
        item.Type__c = change.normalizedType;
      }

      // The vendor's own word for the type, kept beside the normalized one and under the same
      // carried-or-absent rule. Type__c stays a restricted picklist so nothing free-text can
      // reach the public board; Source_Type__c holds what was actually sent, so
      // "which types am I really using" is a GROUP BY rather than a hunch:
      //
      //   SELECT Source_Type__c, COUNT(Id) FROM Work_Item__c
      //   WHERE Type__c = 'Unspecified' GROUP BY Source_Type__c
      //
      // A raw value that shows up often enough earns a place in the picklist. Evidence, not
      // guesswork - and never public: this field is on no DTO and on no guest permission set.
      if (String.isNotBlank(change.remoteType)) {
        item.Source_Type__c = Strings.truncate(
          change.remoteType,
          SOURCE_TYPE_MAX
        );
      }

      toUpsert.add(item);
      applied.add(delivery);
    }

    if (!toUpsert.isEmpty()) {
      // Loop prevention, narrow half: this transaction's DML must not push back out.
      SyncContext.suppressOutbound();
      List<Database.UpsertResult> results;
      try {
        results = Database.upsert(toUpsert, Work_Item__c.External_Id__c, false);
      } finally {
        SyncContext.resumeOutbound();
      }

      List<Delivery> succeeded = new List<Delivery>();
      for (Integer i = 0; i < results.size(); i++) {
        Delivery delivery = applied[i];
        if (results[i].isSuccess()) {
          delivery.workItemId = results[i].getId();
          succeeded.add(delivery);
          String note = delivery.change.normalizedStatus ==
            WorkItemStatus.UNSPECIFIED
            ? 'Applied, but remote status "' +
              delivery.change.remoteStatus +
              '" has no mapping; Status__c set to Unspecified.'
            : null;
          updates.put(
            delivery.eventId,
            terminal(delivery, DeliveryStatus.PROCESSED, note)
          );
        } else {
          updates.put(
            delivery.eventId,
            terminal(delivery, DeliveryStatus.FAILED, errorsOf(results[i]))
          );
        }
      }

      for (Delivery delivery : succeeded) {
        if (delivery.ownerUnresolved) {
          logs.add(
            inboundLog(
              delivery.workItemId,
              'No System Administrator resolved, so ' +
                delivery.change.externalId +
                ' was created owned by Automated Process. Guest sharing rules do not share ' +
                'records owned by that user: if this record is flagged public it will sync ' +
                'correctly and still not appear on the public board. Reassign the owner.'
            )
          );
        }
        if (delivery.projectNote != null) {
          logs.add(inboundLog(delivery.workItemId, delivery.projectNote));
        }
      }
      resolveParents(succeeded, logs);
    }

    // Callouts, if any, finished inside parseAll. All DML happens from here down.
    writeLogs(logs);
    commitEvents(updates.values());
  }

  // ---------- resolution passes ----------

  /**
   * Projects by system and key, for every delivery in the batch that names one. The record
   * rather than the id, because creation also needs its Is_Public__c.
   *
   * One query, whatever the batch size. A key that matches no project, or more than one,
   * resolves to nothing: External_Project_Key__c is not unique, and guessing between two
   * candidates would link work to the wrong project silently, which is worse than leaving it
   * unlinked and saying so.
   */
  private static Map<String, Project__c> resolveProjects(
    List<Delivery> deliveries
  ) {
    Set<String> keys = new Set<String>();
    for (Delivery delivery : deliveries) {
      if (delivery.change.projectKey != null) {
        keys.add(delivery.change.projectKey);
      }
    }
    Map<String, Project__c> byLookup = new Map<String, Project__c>();
    if (keys.isEmpty()) {
      return byLookup;
    }
    Set<String> ambiguous = new Set<String>();
    // Is_Public__c comes back for the inheritance above, so a newly created item can be given
    // its project's visibility without a second query.
    for (Project__c project : [
      SELECT Id, External_Project_Key__c, External_System__c, Is_Public__c
      FROM Project__c
      WHERE External_Project_Key__c IN :keys
    ]) {
      String lookup = lookupKey(
        project.External_System__c,
        project.External_Project_Key__c
      );
      if (byLookup.containsKey(lookup)) {
        ambiguous.add(lookup);
      } else {
        byLookup.put(lookup, project);
      }
    }
    for (String lookup : ambiguous) {
      byLookup.remove(lookup);
    }
    return byLookup;
  }

  /** Nothing to link to, on a record that had nothing to begin with. */
  private static String unlinkedNote(Delivery delivery) {
    return 'Project "' +
      delivery.change.projectKey +
      '" named by ' +
      delivery.change.externalId +
      ' matches no single Project__c with External_Project_Key__c = ' +
      delivery.change.projectKey +
      ' and External_System__c = ' +
      delivery.sourceSystem +
      '. Project__c left null: the record synced, but the public board requires ' +
      'a public parent project, so it cannot appear there until the project is ' +
      'keyed and the issue is delivered again, or the lookup is set by hand.';
  }

  /**
   * The move happened. Both keys are named because the interesting question afterwards is
   * always which project it came from, and the record itself no longer says.
   */
  private static String movedNote(Delivery delivery, Work_Item__c current) {
    return delivery.change.externalId +
      ' moved project in ' +
      delivery.sourceSystem +
      ': "' +
      priorKeyOf(current) +
      '" -> "' +
      delivery.change.projectKey +
      '". Project__c now points at the project carrying the new key. Recorded rather than ' +
      'applied silently because the public board gates on the parent project\'s ' +
      'Is_Public__c, so a move can change who is able to see this record.';
  }

  /** The move was named but cannot be followed. The link the record has is kept. */
  private static String unresolvedMoveNote(
    Delivery delivery,
    Work_Item__c current
  ) {
    return delivery.change.externalId +
      ' names project "' +
      delivery.change.projectKey +
      '", which is not the project it is linked to ("' +
      priorKeyOf(current) +
      '"), but that key matches no single Project__c with External_System__c = ' +
      delivery.sourceSystem +
      '. The existing link is kept: nulling a working link because a lookup failed would ' +
      'hide the record from the board rather than correct it. Key the project and the move ' +
      'is followed on the next delivery.';
  }

  private static String priorKeyOf(Work_Item__c current) {
    String key = current.Project__r == null
      ? null
      : current.Project__r.External_Project_Key__c;
    return String.isBlank(key) ? '(project carries no key)' : key;
  }

  private static String lookupKey(String sourceSystem, String projectKey) {
    return ExternalSystem.namespaceOf(sourceSystem) +
      '|' +
      (projectKey == null ? '' : projectKey.trim().toLowerCase());
  }

  /**
   * Second pass: link children to parents, once every record in the batch exists.
   *
   * Two passes rather than one because a single delivery batch can carry a child and its parent
   * together in either order. Resolving during the first pass would miss a parent that had not
   * been inserted yet, and would do so intermittently - the failure would depend on payload
   * order, which is the worst kind to debug.
   *
   * No stub records. An unresolvable parent leaves Parent_Work_Item__c null and writes a log row
   * naming both sides. A stub would be a titleless, projectless Work_Item__c appearing on the
   * internal board as a blank card, to buy a link the child's next delivery will make anyway.
   *
   * The known cost of that choice: nothing back-fills the link when the parent arrives later.
   * Only a subsequent delivery for the child repairs it. The log row is the record of that gap.
   */
  private static void resolveParents(
    List<Delivery> deliveries,
    List<Integration_Log__c> logs
  ) {
    Map<String, Id> idByExternalId = new Map<String, Id>();
    for (Delivery delivery : deliveries) {
      idByExternalId.put(delivery.change.externalId, delivery.workItemId);
    }

    Set<String> wanted = new Set<String>();
    for (Delivery delivery : deliveries) {
      String parentExternalId = delivery.change.parentExternalId;
      if (
        parentExternalId != null &&
        !idByExternalId.containsKey(parentExternalId)
      ) {
        wanted.add(parentExternalId);
      }
    }
    // One query, and only for parents this batch did not itself carry - the batch's own records
    // are already keyed above, straight off the upsert results.
    if (!wanted.isEmpty()) {
      for (Work_Item__c parent : [
        SELECT Id, External_Id__c
        FROM Work_Item__c
        WHERE External_Id__c IN :wanted
      ]) {
        idByExternalId.put(parent.External_Id__c, parent.Id);
      }
    }

    List<Work_Item__c> links = new List<Work_Item__c>();
    List<Delivery> linked = new List<Delivery>();
    for (Delivery delivery : deliveries) {
      InboundChange change = delivery.change;
      if (change.parentExternalId == null) {
        continue;
      }
      Id parentId = idByExternalId.get(change.parentExternalId);
      if (parentId == null) {
        // Surfaced, not fatal. The delivery is still Processed: an unresolved reference is a
        // data gap, and dropping a status change on account of one would trade a visible
        // problem for an invisible one.
        logs.add(
          inboundLog(
            delivery.workItemId,
            'Parent ' +
              change.parentExternalId +
              ' referenced by ' +
              change.externalId +
              ' is not a Work_Item__c Salesforce has seen. Parent_Work_Item__c left null; the ' +
              'status change in this delivery was applied. The link is made when the child is ' +
              'next delivered, by which time the parent will normally exist.'
          )
        );
        continue;
      }
      if (parentId == delivery.workItemId) {
        // Nothing in the schema stops a self-lookup pointing at its own row, and a cycle of
        // length one is still a cycle for anything walking ancestors.
        logs.add(
          inboundLog(
            delivery.workItemId,
            'Payload for ' +
              change.externalId +
              ' names itself as its own parent. Parent_Work_Item__c left null.'
          )
        );
        continue;
      }
      links.add(
        new Work_Item__c(
          Id = delivery.workItemId,
          Parent_Work_Item__c = parentId
        )
      );
      linked.add(delivery);
    }

    if (links.isEmpty()) {
      return;
    }

    // Suppressed for the same reason the upsert is. Parent_Work_Item__c is not Status__c, so
    // the trigger's delta check would not fire outbound anyway - but relying on that couples
    // this to a detail of another class.
    SyncContext.suppressOutbound();
    List<Database.SaveResult> linkResults;
    try {
      linkResults = Database.update(links, false);
    } finally {
      SyncContext.resumeOutbound();
    }

    for (Integer i = 0; i < linkResults.size(); i++) {
      if (linkResults[i].isSuccess()) {
        continue;
      }
      logs.add(
        inboundLog(
          linked[i].workItemId,
          'Could not link ' +
            linked[i].change.externalId +
            ' to parent ' +
            linked[i].change.parentExternalId +
            ': ' +
            errorsOf(linkResults[i])
        )
      );
    }
  }

  // ---------- ownership ----------

  /**
   * The user that should own records this subscriber creates.
   *
   * Resolved once per transaction and cached. Returning null is a tolerated outcome: the record
   * still syncs, it is simply owned by Automated Process and therefore not visible to guests.
   * Failing the whole delivery over an ownership nicety would be worse.
   *
   * Profile name is admittedly brittle - a dedicated integration user, named in configuration,
   * is the better long-term answer.
   */
  @TestVisible
  private static Id integrationOwner;
  @TestVisible
  private static Boolean integrationOwnerResolved = false;

  private static Id integrationOwnerId() {
    if (integrationOwnerResolved) {
      return integrationOwner;
    }
    integrationOwnerResolved = true;
    List<User> admins = [
      SELECT Id
      FROM User
      WHERE IsActive = TRUE AND Profile.Name = 'System Administrator'
      ORDER BY CreatedDate ASC
      LIMIT 1
    ];
    integrationOwner = admins.isEmpty() ? null : admins[0].Id;
    return integrationOwner;
  }

  // ---------- parsing ----------

  /**
   * Groups the batch by source system and lets each system's adapter read its own rows, once.
   *
   * One call per system, not per event. That is what lets an adapter deduplicate the resources
   * a batch refers to and fetch them a few at a time; a call per event could only ever fetch
   * one at a time, and a failure half way through would leave a loop this class cannot resume.
   * This class still learns nothing about any payload - it hands over rows and gets back
   * InboundChange objects, each naming the delivery it came from.
   *
   * Nothing here writes. An adapter may call out from parseInbound, so the first DML in this
   * transaction must come after this method returns.
   *
   * @param logs collects whatever the adapters buffered; written by the caller, after the upsert
   */
  private static List<Delivery> parseAll(
    List<Webhook_Event__c> rows,
    List<Integration_Log__c> logs
  ) {
    List<Delivery> deliveries = new List<Delivery>();
    Map<Id, Delivery> byEventId = new Map<Id, Delivery>();
    Map<String, List<Webhook_Event__c>> rowsByNamespace = new Map<String, List<Webhook_Event__c>>();

    for (Webhook_Event__c row : rows) {
      Delivery delivery = new Delivery();
      delivery.eventId = row.Id;
      delivery.sourceSystem = row.Source_System__c;
      deliveries.add(delivery);
      byEventId.put(row.Id, delivery);

      String namespace = ExternalSystem.namespaceOf(row.Source_System__c);
      if (String.isBlank(namespace)) {
        delivery.failure = 'Delivery names no source system.';
        continue;
      }
      if (!rowsByNamespace.containsKey(namespace)) {
        rowsByNamespace.put(namespace, new List<Webhook_Event__c>());
      }
      rowsByNamespace.get(namespace).add(row);
    }

    for (String namespace : rowsByNamespace.keySet()) {
      List<Webhook_Event__c> batch = rowsByNamespace.get(namespace);

      IWorkItemAdapter adapter;
      try {
        adapter = WorkItemAdapterFactory.forSystem(namespace);
      } catch (Exception e) {
        failBatch(
          batch,
          byEventId,
          'No adapter for source system "' +
            batch[0].Source_System__c +
            '": ' +
            Strings.describe(e)
        );
        continue;
      }

      List<InboundChange> changes;
      try {
        changes = adapter.parseInbound(batch);
      } catch (Exception e) {
        // The interface contracts not to throw for a payload it cannot use, so anything here
        // is genuinely unexpected. One system's batch fails; another system's does not.
        failBatch(
          batch,
          byEventId,
          'The adapter for "' +
            batch[0].Source_System__c +
            '" could not read this batch: ' +
            Strings.describe(e)
        );
        logs.addAll(adapter.drainLogs());
        continue;
      }
      logs.addAll(adapter.drainLogs());

      if (changes == null) {
        continue;
      }
      for (InboundChange change : changes) {
        // Correlated by the id the adapter stamped on the change, never by position: the
        // returned list is allowed to be shorter than the batch it was given.
        Delivery delivery = change.sourceEventId == null
          ? null
          : byEventId.get(change.sourceEventId);
        if (delivery == null) {
          continue;
        }
        delivery.change = change;
        delivery.failure = change.failure;
      }
    }
    return deliveries;
  }

  private static void failBatch(
    List<Webhook_Event__c> batch,
    Map<Id, Delivery> byEventId,
    String failure
  ) {
    for (Webhook_Event__c row : batch) {
      byEventId.get(row.Id).failure = failure;
    }
  }

  // ---------- helpers ----------

  private static Webhook_Event__c superseded(Delivery delivery) {
    return terminal(
      delivery,
      DeliveryStatus.IGNORED,
      'Superseded within the same batch by a newer delivery.'
    );
  }

  private static Webhook_Event__c terminal(
    Delivery delivery,
    String status,
    String note
  ) {
    InboundChange change = delivery.change;
    return new Webhook_Event__c(
      Id = delivery.eventId,
      Processing_Status__c = status,
      Event_Type__c = change == null
        ? null
        : Strings.truncate(change.eventType, EVENT_TYPE_MAX),
      External_Id__c = change == null
        ? null
        : Strings.truncate(change.externalId, EXTERNAL_ID_MAX),
      Error_Message__c = Strings.truncate(note, EVENT_ERROR_MAX)
    );
  }

  /**
   * An Integration_Log__c row describing a processing outcome rather than a callout.
   *
   * Endpoint__c and HTTP_Method__c stay null on purpose: no HTTP happened. Is_Success__c is
   * false because every caller here is reporting something that did not go as intended - the
   * delivery succeeded, but a piece of it did not land.
   */
  private static Integration_Log__c inboundLog(Id workItemId, String message) {
    return new Integration_Log__c(
      Direction__c = LogDirection.INBOUND,
      Is_Success__c = false,
      Work_Item__c = workItemId,
      Error_Message__c = Strings.truncate(message, LOG_ERROR_MAX)
    );
  }

  private static String errorsOf(Database.UpsertResult result) {
    return errorsOf(result.getErrors());
  }

  private static String errorsOf(Database.SaveResult result) {
    return errorsOf(result.getErrors());
  }

  private static String errorsOf(List<Database.Error> errors) {
    List<String> messages = new List<String>();
    for (Database.Error error : errors) {
      messages.add(error.getStatusCode() + ': ' + error.getMessage());
    }
    return String.join(messages, ' | ');
  }

  /**
   * Allow-partial, and never allowed to throw. These rows exist to report problems; a failure
   * to write one must not become a second, larger problem by failing the delivery that was
   * otherwise fine.
   */
  private static void writeLogs(List<Integration_Log__c> logs) {
    if (logs.isEmpty()) {
      return;
    }
    try {
      Database.insert(logs, false);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'Could not write Integration_Log__c rows: ' + e.getMessage()
      );
    }
  }

  private static void commitEvents(List<Webhook_Event__c> events) {
    if (events.isEmpty()) {
      return;
    }
    try {
      Database.update(events, false);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'Could not write Webhook_Event__c outcomes: ' + e.getMessage()
      );
    }
  }
}
