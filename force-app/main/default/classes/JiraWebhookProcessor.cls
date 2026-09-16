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
    Datetime remoteUpdated;
    String failure; // non-null means the event cannot be applied
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
        }
      }

      // Only when the payload actually carried one. Assigning a null would blank a title
      // we already hold, and a delivery that omits the summary is not a retitling.
      if (String.isNotBlank(event.title)) {
        item.Title__c = event.title;
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

      for (Integer i = 0; i < results.size(); i++) {
        ParsedEvent event = applied[i];
        if (results[i].isSuccess()) {
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
    }

    commitEvents(updates.values());
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
