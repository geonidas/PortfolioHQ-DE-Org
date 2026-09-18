/**
 * Applies verified Jira webhooks to Work_Item__c, in the platform event subscriber's transaction.
 *
 * Runs as the Automated Process user, not the guest who received the delivery - that user switch
 * is the entire reason the platform event exists. This is also the first point at which the
 * payload is deserialised: by now the signature has proved it came from Jira.
 *
 * Loop prevention lives here, in two parts. The timestamp comparison is the durable one and
 * decides whether a change is applied at all. The SyncContext suppression is narrower - it only
 * covers this transaction's DML, stopping the outbound trigger from pushing straight back.
 */
public with sharing class JiraWebhookProcessor {
  private static final String SYSTEM_NAMESPACE = 'jira';
  private static final Integer ERROR_MAX = 32768;
  private static final Integer TITLE_MAX = 255;

  /** One payload, reduced to the parts this build acts on. */
  private class ParsedEvent {
    Id eventId;
    String eventType;
    String externalId; // namespaced, e.g. jira:10039
    String externalKey;
    String title;
    String remoteStatus;
    String normalizedStatus;
    String remoteType;
    String normalizedType; // null means the payload carried no usable issuetype
    String parentExternalId; // namespaced; null means the payload carried no parent
    Datetime remoteUpdated;
    String failure; // non-null means the event cannot be applied
    Boolean ownerUnresolved = false;
    Id workItemId; // filled from the upsert result, for the second pass
  }

  /** Subscriber entry point. */
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
    process(
      [
        SELECT Id, Raw_Payload__c, Processing_Status__c, Signature_Valid__c
        FROM Webhook_Event__c
        WHERE
          Id IN :eventIds
          AND Processing_Status__c = 'Pending'
          AND Signature_Valid__c = TRUE
      ]
    );
  }

  /**
   * Bulk-safe. Callable directly so tests can exercise processing without standing up the
   * event bus.
   */
  public static void process(List<Webhook_Event__c> rows) {
    if (rows == null || rows.isEmpty()) {
      return;
    }

    IWorkItemAdapter adapter = WorkItemAdapterFactory.forSystem(
      SYSTEM_NAMESPACE
    );
    Map<Id, Webhook_Event__c> updates = new Map<Id, Webhook_Event__c>();
    List<ParsedEvent> parsed = new List<ParsedEvent>();

    for (Webhook_Event__c row : rows) {
      ParsedEvent event = parse(row, adapter);
      parsed.add(event);
      if (event.failure != null) {
        updates.put(row.Id, terminal(row.Id, event, 'Failed', event.failure));
      }
    }

    // Several deliveries in one batch can concern one issue. Keep only the newest per issue
    // and retire the rest as Ignored, so a bulk batch cannot apply an older state last.
    Map<String, ParsedEvent> newestByExternalId = new Map<String, ParsedEvent>();
    for (ParsedEvent event : parsed) {
      if (event.failure != null) {
        continue;
      }
      ParsedEvent held = newestByExternalId.get(event.externalId);
      if (held == null || event.remoteUpdated > held.remoteUpdated) {
        if (held != null) {
          updates.put(
            held.eventId,
            terminal(
              held.eventId,
              held,
              'Ignored',
              'Superseded within the same batch by a newer delivery.'
            )
          );
        }
        newestByExternalId.put(event.externalId, event);
      } else {
        updates.put(
          event.eventId,
          terminal(
            event.eventId,
            event,
            'Ignored',
            'Superseded within the same batch by a newer delivery.'
          )
        );
      }
    }
    if (newestByExternalId.isEmpty()) {
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
        Remote_Last_Modified__c
      FROM Work_Item__c
      WHERE External_Id__c IN :newestByExternalId.keySet()
    ]) {
      existing.put(item.External_Id__c, item);
    }

    List<Work_Item__c> toUpsert = new List<Work_Item__c>();
    List<ParsedEvent> applied = new List<ParsedEvent>();

    for (ParsedEvent event : newestByExternalId.values()) {
      Work_Item__c current = existing.get(event.externalId);

      // Loop prevention, durable half. A delivery that is not strictly newer than what we
      // already hold changes nothing - that covers the echo of our own push, a duplicate
      // delivery, and an out-of-order one, without needing to know which it was.
      if (
        current != null &&
        current.Remote_Last_Modified__c != null &&
        event.remoteUpdated <= current.Remote_Last_Modified__c
      ) {
        updates.put(
          event.eventId,
          terminal(
            event.eventId,
            event,
            'Ignored',
            'Payload is not newer than Remote_Last_Modified__c; nothing applied.'
          )
        );
        continue;
      }

      Work_Item__c item = new Work_Item__c(
        External_Id__c = event.externalId,
        External_Key__c = event.externalKey,
        External_System__c = 'Jira',
        Status__c = event.normalizedStatus,
        Remote_Last_Modified__c = event.remoteUpdated,
        Last_Synced__c = System.now(),
        // Synced is illegal alongside an Unspecified status - see the
        // Sync_Status_Requires_Known_Status validation rule. An unmapped remote status
        // therefore stays Pending, which is also honest: we have not reconciled it.
        Sync_Status__c = event.normalizedStatus == 'Unspecified'
          ? 'Pending'
          : 'Synced'
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
          // Build 05 left this silent. The record still syncs, but it stays owned by Automated
          // Process, and guest sharing rules do not share those - so it is public, synced and
          // invisible, with nothing anywhere saying so. Logged after the upsert, once there is
          // a record id to point the row at.
          event.ownerUnresolved = true;
        }
      }

      // Only when the payload actually carried one. Assigning a null would blank a title
      // we already hold, and a delivery that omits the summary is not a retitling.
      if (String.isNotBlank(event.title)) {
        item.Title__c = event.title;
      }

      // The same rule, for the same reason. Most deliveries here are status transitions, whose
      // payloads carry no issuetype at all; assigning a null would blank a known type on every
      // one of them. Unspecified, by contrast, is a real value the payload asked for.
      if (String.isNotBlank(event.normalizedType)) {
        item.Type__c = event.normalizedType;
      }

      toUpsert.add(item);
      applied.add(event);
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

      List<ParsedEvent> succeeded = new List<ParsedEvent>();
      for (Integer i = 0; i < results.size(); i++) {
        ParsedEvent event = applied[i];
        if (results[i].isSuccess()) {
          event.workItemId = results[i].getId();
          succeeded.add(event);
          String note = event.normalizedStatus == 'Unspecified'
            ? 'Applied, but remote status "' +
              event.remoteStatus +
              '" has no mapping; Status__c set to Unspecified.'
            : null;
          updates.put(
            event.eventId,
            terminal(event.eventId, event, 'Processed', note)
          );
        } else {
          List<String> messages = new List<String>();
          for (Database.Error error : results[i].getErrors()) {
            messages.add(error.getStatusCode() + ': ' + error.getMessage());
          }
          updates.put(
            event.eventId,
            terminal(
              event.eventId,
              event,
              'Failed',
              String.join(messages, ' | ')
            )
          );
        }
      }

      List<Integration_Log__c> logs = new List<Integration_Log__c>();
      for (ParsedEvent event : succeeded) {
        if (event.ownerUnresolved) {
          logs.add(
            inboundLog(
              event.workItemId,
              'No System Administrator resolved, so ' +
                event.externalId +
                ' was created owned by Automated Process. Guest sharing rules do not share ' +
                'records owned by that user: if this record is flagged public it will sync ' +
                'correctly and still not appear on the public board. Reassign the owner.'
            )
          );
        }
      }
      resolveParents(succeeded, logs);
      writeLogs(logs);
    }

    commitEvents(updates.values());
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
    List<ParsedEvent> events,
    List<Integration_Log__c> logs
  ) {
    Map<String, Id> idByExternalId = new Map<String, Id>();
    for (ParsedEvent event : events) {
      idByExternalId.put(event.externalId, event.workItemId);
    }

    Set<String> wanted = new Set<String>();
    for (ParsedEvent event : events) {
      if (
        event.parentExternalId != null &&
        !idByExternalId.containsKey(event.parentExternalId)
      ) {
        wanted.add(event.parentExternalId);
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
    List<ParsedEvent> linked = new List<ParsedEvent>();
    for (ParsedEvent event : events) {
      if (event.parentExternalId == null) {
        continue;
      }
      Id parentId = idByExternalId.get(event.parentExternalId);
      if (parentId == null) {
        // Surfaced, not fatal. The delivery is still Processed: an unresolved reference is a
        // data gap, and dropping a status change on account of one would trade a visible
        // problem for an invisible one.
        logs.add(
          inboundLog(
            event.workItemId,
            'Parent ' +
              event.parentExternalId +
              ' referenced by ' +
              event.externalId +
              ' is not a Work_Item__c Salesforce has seen. Parent_Work_Item__c left null; the ' +
              'status change in this delivery was applied. The link is made when the child is ' +
              'next delivered, by which time the parent will normally exist.'
          )
        );
        continue;
      }
      if (parentId == event.workItemId) {
        // Nothing in the schema stops a self-lookup pointing at its own row, and a cycle of
        // length one is still a cycle for anything walking ancestors.
        logs.add(
          inboundLog(
            event.workItemId,
            'Payload for ' +
              event.externalId +
              ' names itself as its own parent. Parent_Work_Item__c left null.'
          )
        );
        continue;
      }
      links.add(
        new Work_Item__c(Id = event.workItemId, Parent_Work_Item__c = parentId)
      );
      linked.add(event);
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
      List<String> messages = new List<String>();
      for (Database.Error error : linkResults[i].getErrors()) {
        messages.add(error.getStatusCode() + ': ' + error.getMessage());
      }
      logs.add(
        inboundLog(
          linked[i].workItemId,
          'Could not link ' +
            linked[i].externalId +
            ' to parent ' +
            linked[i].parentExternalId +
            ': ' +
            String.join(messages, ' | ')
        )
      );
    }
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
      Direction__c = 'Inbound',
      Is_Success__c = false,
      Work_Item__c = workItemId,
      Error_Message__c = truncate(message, ERROR_MAX)
    );
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

  private static ParsedEvent parse(
    Webhook_Event__c row,
    IWorkItemAdapter adapter
  ) {
    ParsedEvent event = new ParsedEvent();
    event.eventId = row.Id;

    if (String.isBlank(row.Raw_Payload__c)) {
      event.failure = 'Empty payload.';
      return event;
    }

    Map<String, Object> payload;
    try {
      payload = (Map<String, Object>) JSON.deserializeUntyped(
        row.Raw_Payload__c
      );
    } catch (Exception e) {
      event.failure =
        'Malformed JSON: ' +
        e.getTypeName() +
        ': ' +
        e.getMessage();
      return event;
    }

    event.eventType = asString(payload.get('webhookEvent'));

    Map<String, Object> issue = asMap(payload.get('issue'));
    if (issue == null) {
      event.failure = 'Payload carries no issue object.';
      return event;
    }

    String rawId = asString(issue.get('id'));
    if (String.isBlank(rawId)) {
      event.failure = 'Payload carries no issue id.';
      return event;
    }
    event.externalId = ExternalIdUtil.qualify(SYSTEM_NAMESPACE, rawId);
    event.externalKey = asString(issue.get('key'));

    Map<String, Object> fields = asMap(issue.get('fields'));
    if (fields == null) {
      event.failure = 'Payload carries no issue fields.';
      return event;
    }

    // Jira's summary is the only thing in the payload a person would call the task's name.
    // Truncated rather than rejected: a title too long for the field is a display problem,
    // not a reason to drop a status change on the floor.
    event.title = truncate(asString(fields.get('summary')), TITLE_MAX);

    // Type and parent are read here but assigned further down only when the payload actually
    // carried them. Both are standard Jira fields, so "carried it" needs no configuration to
    // decide - the object is either in the payload or it is not.
    Map<String, Object> issueType = asMap(fields.get('issuetype'));
    if (issueType != null) {
      event.remoteType = asString(issueType.get('name'));
      // A blank name is treated as absent rather than unmapped. An issuetype object with no
      // name is malformed, and writing Unspecified over a type we already hold on the strength
      // of malformed input is worse than leaving it alone.
      if (String.isNotBlank(event.remoteType)) {
        event.normalizedType = adapter.normalizeType(event.remoteType);
      }
    }

    // The reference only. Resolving it to a record happens after the upsert, because the
    // parent may be arriving in this very batch - see resolveParents.
    Map<String, Object> parentRef = asMap(fields.get('parent'));
    if (parentRef != null) {
      String parentRawId = asString(parentRef.get('id'));
      if (String.isNotBlank(parentRawId)) {
        event.parentExternalId = ExternalIdUtil.qualify(
          SYSTEM_NAMESPACE,
          parentRawId
        );
      }
    }

    Map<String, Object> status = asMap(fields.get('status'));
    event.remoteStatus = status == null ? null : asString(status.get('name'));
    event.normalizedStatus = adapter.normalizeStatus(event.remoteStatus);

    // issue.fields.updated, not the envelope's own timestamp: the envelope says when the
    // event fired, which on a redelivery is not when the issue changed.
    event.remoteUpdated = parseIso(asString(fields.get('updated')));
    if (event.remoteUpdated == null) {
      event.failure = 'Payload carries no usable issue.fields.updated timestamp.';
      return event;
    }
    return event;
  }

  /**
   * Jira sends ISO-8601 with a four digit offset (+0000). Insert the colon before handing it
   * to the JSON parser, which wants an RFC-3339 shaped offset.
   */
  @TestVisible
  private static Datetime parseIso(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    String text = value.trim();
    if (text.length() > 5) {
      String tail = text.substring(text.length() - 5);
      if (
        (tail.startsWith('+') || tail.startsWith('-')) &&
        tail.substring(1).isNumeric()
      ) {
        text =
          text.substring(0, text.length() - 2) +
          ':' +
          text.substring(text.length() - 2);
      }
    }
    try {
      return (Datetime) JSON.deserialize('"' + text + '"', Datetime.class);
    } catch (Exception e) {
      return null;
    }
  }

  // ---------- helpers ----------

  private static Webhook_Event__c terminal(
    Id eventId,
    ParsedEvent event,
    String status,
    String note
  ) {
    return new Webhook_Event__c(
      Id = eventId,
      Processing_Status__c = status,
      Event_Type__c = event == null ? null : truncate(event.eventType, 80),
      External_Id__c = event == null ? null : truncate(event.externalId, 50),
      Error_Message__c = truncate(note, ERROR_MAX)
    );
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

  private static Map<String, Object> asMap(Object value) {
    return value instanceof Map<String, Object>
      ? (Map<String, Object>) value
      : null;
  }

  private static String asString(Object value) {
    return value == null ? null : String.valueOf(value);
  }

  private static String truncate(String value, Integer maxLength) {
    if (value == null || value.length() <= maxLength) {
      return value;
    }
    return value.substring(0, maxLength - 3) + '...';
  }
}
