/**
 * Jira Cloud implementation of IWorkItemAdapter.
 *
 * Everything Jira-shaped is confined here: the named credential, the /rest/api/3 paths, the
 * response envelope, the webhook payload shape, and the mapping between Jira's workflow status
 * and issue type names and our normalized Work_Item__c values.
 *
 * A status change is two callouts, not one. Jira will not accept a target status directly - you
 * ask which transitions are legal from the issue's current state, then post the id of the one
 * whose TARGET status matches. Transition ids are per-workflow and are never hardcoded. Title
 * and date edits are one more: a single PUT carrying only the fields that changed.
 *
 * Callout budget: at most 3 calls per item, against a limit of 100 callouts and 120 seconds of
 * cumulative callout time per transaction - see WorkItemSyncService for how work is chunked.
 */
public with sharing class JiraAdapter implements IWorkItemAdapter {
  @TestVisible
  private static final String NAMED_CREDENTIAL = 'Jira_Classic';
  @TestVisible
  private static final String SYSTEM_NAMESPACE = ExternalSystem.JIRA_NAMESPACE;
  private static final String API_BASE = '/rest/api/3';
  private static final Integer TIMEOUT_MS = 10000;
  private static final Integer ENDPOINT_MAX = Integration_Log__c.Endpoint__c.getDescribe()
    .getLength();
  private static final Integer BODY_MAX = Integration_Log__c.Request_Body__c.getDescribe()
    .getLength();
  private static final Integer TITLE_MAX = Work_Item__c.Title__c.getDescribe()
    .getLength();
  private static final Integer DESCRIPTION_MAX = Work_Item__c.Description__c.getDescribe()
    .getLength();

  /** The Work_Item__c field whose Jira counterpart is configuration, not a constant. */
  private static final String START_DATE_FIELD = String.valueOf(
    Work_Item__c.Start_Date__c
  );

  /**
   * ADF node types whose children are inline text, joined without a separator. Every other
   * container's children are blocks and go on separate lines. See plainText.
   */
  private static final Set<String> INLINE_PARENTS = new Set<String>{
    'paragraph',
    'heading',
    'codeBlock'
  };

  /**
   * Jira workflow status names that count as each of our normalized statuses.
   *
   * Hardcoded on purpose for this build: Field_Mapping__mdt is out of scope, and this is the
   * table it will replace. Names are compared normalized - lowercased, whitespace collapsed.
   */
  private static final Map<String, Set<String>> STATUS_ALIASES = new Map<String, Set<String>>{
    WorkItemStatus.TO_DO => new Set<String>{
      'to do',
      'todo',
      'open',
      'backlog',
      'new',
      'reopened'
    },
    WorkItemStatus.IN_PROGRESS => new Set<String>{
      'in progress',
      'inprogress',
      'in development',
      'started'
    },
    WorkItemStatus.IN_REVIEW => new Set<String>{
      'in review',
      'review',
      'code review',
      'in qa',
      'qa'
    },
    WorkItemStatus.DONE => new Set<String>{
      'done',
      'closed',
      'resolved',
      'complete',
      'completed'
    }
  };

  /**
   * Jira issue type names that count as each of our normalized Type__c values.
   *
   * Hardcoded alongside STATUS_ALIASES and for the same reason. Two judgement calls are worth
   * naming because both are reversible in one line here:
   *
   * - Jira's 'Sub-task' maps to Task. Type__c is restricted and has no Subtask value, so the
   *   alternative is Unspecified. A subtask is a unit of work; calling it a Task is a
   *   flattening, not a lie, and it reads better on the board than a blank.
   * - Nothing maps to Unspecified deliberately. It is only ever the catch-all, which keeps
   *   "we have not mapped this" distinguishable from "Jira says it is unspecified".
   */
  private static final Map<String, Set<String>> TYPE_ALIASES = new Map<String, Set<String>>{
    WorkItemType.EPIC => new Set<String>{ 'epic' },
    WorkItemType.STORY => new Set<String>{ 'story', 'user story' },
    WorkItemType.BUG => new Set<String>{ 'bug', 'defect', 'fault' },
    WorkItemType.TASK => new Set<String>{
      'task',
      'sub-task',
      'subtask',
      'sub task'
    },
    WorkItemType.SPIKE => new Set<String>{
      'spike',
      'research',
      'investigation'
    }
  };

  private final List<Integration_Log__c> pendingLogs = new List<Integration_Log__c>();

  /**
   * Reverse of the match() lookup, reading the same STATUS_ALIASES table so the mapping is
   * defined exactly once. Extracting it to custom metadata later is therefore one refactor,
   * not two.
   */
  public String normalizeStatus(String remoteStatusName) {
    String candidate = normalize(remoteStatusName);
    if (String.isBlank(candidate)) {
      return WorkItemStatus.UNSPECIFIED;
    }
    for (String normalized : STATUS_ALIASES.keySet()) {
      if (
        normalize(normalized) == candidate ||
        STATUS_ALIASES.get(normalized).contains(candidate)
      ) {
        return normalized;
      }
    }
    // A workflow status we have no mapping for lands on the catch-all, exactly as an
    // unmappable status does on the way out.
    return WorkItemStatus.UNSPECIFIED;
  }

  /** Same lookup shape as normalizeStatus, over the type table. */
  public String normalizeType(String remoteTypeName) {
    String candidate = normalize(remoteTypeName);
    if (String.isBlank(candidate)) {
      return WorkItemType.UNSPECIFIED;
    }
    for (String normalized : TYPE_ALIASES.keySet()) {
      if (
        normalize(normalized) == candidate ||
        TYPE_ALIASES.get(normalized).contains(candidate)
      ) {
        return normalized;
      }
    }
    // A custom Jira issue type lands on the catch-all rather than failing the delivery.
    return WorkItemType.UNSPECIFIED;
  }

  public List<Integration_Log__c> drainLogs() {
    List<Integration_Log__c> drained = new List<Integration_Log__c>(
      pendingLogs
    );
    pendingLogs.clear();
    return drained;
  }

  // ---------- inbound ----------

  /**
   * Reads a batch of jira:issue_updated deliveries.
   *
   * Jira's payloads are fat - every field the processor needs is already in the body - so this
   * issues no callout and the batch is only a loop. It is batch-shaped because the interface is,
   * and the interface is because Asana's payloads are thin enough to need a fetch per resource.
   *
   * One event that cannot be read does not discard the rest. Each is parsed inside its own
   * try/catch, an unusable one comes back carrying `failure` so the caller can retire that
   * delivery, and a buffered Integration_Log__c row names the event either way.
   */
  public List<InboundChange> parseInbound(List<Webhook_Event__c> events) {
    List<InboundChange> changes = new List<InboundChange>();
    if (events == null || events.isEmpty()) {
      return changes;
    }
    for (Webhook_Event__c event : events) {
      InboundChange change;
      try {
        change = parseOne(event.Raw_Payload__c);
      } catch (Exception e) {
        // parseOne contracts not to throw, so anything here is genuinely unexpected. Caught
        // per event so one bad body cannot cost the other forty-nine.
        change = new InboundChange();
        change.failure = 'Could not read the payload: ' + Strings.describe(e);
      }
      change.sourceEventId = event.Id;
      if (!change.isUsable()) {
        logUnreadable(event, change.failure);
      }
      changes.add(change);
    }
    return changes;
  }

  /**
   * An Integration_Log__c row for a delivery that could not be read.
   *
   * Buffered rather than inserted, like every other row this class produces: DML here would
   * break the next callout in the transaction. The body is deliberately not copied into the
   * row - it is already on Webhook_Event__c.Raw_Payload__c, and duplicating an unparseable
   * payload into the log buys nothing.
   */
  private void logUnreadable(Webhook_Event__c event, String failure) {
    pendingLogs.add(
      new Integration_Log__c(
        Direction__c = LogDirection.INBOUND,
        Is_Success__c = false,
        Status_Code__c = 0,
        Error_Message__c = Strings.truncate(
          'Delivery ' +
            (event.Id == null ? '(unsaved)' : String.valueOf(event.Id)) +
            ' could not be read and was skipped; the rest of the batch was not affected. ' +
            failure,
          BODY_MAX
        )
      )
    );
  }

  /**
   * Reads one jira:issue_updated delivery. This is the only place that knows the payload's shape.
   *
   * Optional fields - summary, issuetype, parent, project - are set on the change only when the
   * payload actually carries them, because most deliveries are status transitions carrying
   * none of them, and the processor must be able to tell "not sent" from "sent empty". An
   * issuetype object present but with a blank name counts as absent, not as unmapped: writing
   * Unspecified over a known type on the strength of malformed input is worse than leaving it.
   *
   * Two things are read from the issue, not the envelope. The id is issue.id, the stable
   * numeric one, never the key, which changes when an issue moves project. The timestamp is
   * issue.fields.updated, because the envelope's own timestamp says when the event fired,
   * which on a redelivery is not when the issue changed.
   */
  private InboundChange parseOne(String rawPayload) {
    InboundChange change = new InboundChange();
    if (String.isBlank(rawPayload)) {
      change.failure = 'Empty payload.';
      return change;
    }

    Map<String, Object> payload;
    try {
      payload = (Map<String, Object>) JSON.deserializeUntyped(rawPayload);
    } catch (Exception e) {
      change.failure = 'Malformed JSON: ' + Strings.describe(e);
      return change;
    }

    change.eventType = asString(payload.get('webhookEvent'));

    Map<String, Object> issue = asMap(payload.get('issue'));
    if (issue == null) {
      change.failure = 'Payload carries no issue object.';
      return change;
    }

    String rawId = asString(issue.get('id'));
    if (String.isBlank(rawId)) {
      change.failure = 'Payload carries no issue id.';
      return change;
    }
    change.externalId = ExternalIdUtil.qualify(SYSTEM_NAMESPACE, rawId);
    change.externalKey = asString(issue.get('key'));

    Map<String, Object> fields = asMap(issue.get('fields'));
    if (fields == null) {
      change.failure = 'Payload carries no issue fields.';
      return change;
    }

    // Jira's summary is the only thing in the payload a person would call the task's name.
    // Truncated rather than rejected: a title too long for the field is a display problem,
    // not a reason to drop a status change on the floor.
    change.title = Strings.truncate(asString(fields.get('summary')), TITLE_MAX);

    Map<String, Object> issueType = asMap(fields.get('issuetype'));
    if (issueType != null) {
      change.remoteType = asString(issueType.get('name'));
      if (String.isNotBlank(change.remoteType)) {
        change.normalizedType = normalizeType(change.remoteType);
      }
    }

    // The reference only. Resolving it to a record is the processor's second pass, because
    // the parent may be arriving in the same batch.
    Map<String, Object> parentRef = asMap(fields.get('parent'));
    if (parentRef != null) {
      String parentRawId = asString(parentRef.get('id'));
      if (String.isNotBlank(parentRawId)) {
        change.parentExternalId = ExternalIdUtil.qualify(
          SYSTEM_NAMESPACE,
          parentRawId
        );
      }
    }

    // The project key, not its numeric id: the key is what a person types into
    // Project__c.External_Project_Key__c, and it is what the JQL filter on the webhook uses.
    Map<String, Object> project = asMap(fields.get('project'));
    if (project != null) {
      String projectKey = asString(project.get('key'));
      if (String.isNotBlank(projectKey)) {
        change.projectKey = projectKey;
      }
    }

    Map<String, Object> status = asMap(fields.get('status'));
    change.remoteStatus = status == null ? null : asString(status.get('name'));
    change.normalizedStatus = normalizeStatus(change.remoteStatus);

    // When the issue was made, in the same wire format as updated - including the site's local
    // offset, which is what parseIso's four-digit handling exists for (DOPP-20).
    change.sourceCreated = parseIso(asString(fields.get('created')));

    // These three can be emptied in Jira, so a key that is present with a null value is a
    // real value - "none" - and has to clear what Salesforce holds. A key that is absent is
    // not carried. Jira's webhook sends the full field set, so in practice all three are
    // carried on every delivery.
    if (fields.containsKey('duedate')) {
      carryDay(change, fields.get('duedate'), 'duedate', false);
    }
    String startField = startDateFieldId();
    if (startField != null && fields.containsKey(startField)) {
      carryDay(change, fields.get(startField), startField, true);
    }
    if (fields.containsKey('description')) {
      change.carryDescription(
        Strings.truncate(plainText(fields.get('description')), DESCRIPTION_MAX)
      );
    }
    if (fields.containsKey('priority')) {
      carryPriority(change, fields.get('priority'));
    }

    change.remoteUpdated = parseIso(asString(fields.get('updated')));
    if (change.remoteUpdated == null) {
      change.failure = 'Payload carries no usable issue.fields.updated timestamp.';
      return change;
    }
    return change;
  }

  /**
   * The Jira field that holds the start date, from a Field_Mapping__mdt row of type Field.
   *
   * Custom field ids differ between Jira sites - customfield_10015 is this one's - so the id is
   * configuration and never a constant. Null when no row exists, and then start dates are
   * neither read nor pushed; whether a source supports start dates at all is a separate fact,
   * in Board_Source__mdt.
   */
  @TestVisible
  private static String startDateFieldId() {
    return FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.FIELD,
      START_DATE_FIELD
    );
  }

  /**
   * A Jira date field onto the change. A value that is not a real YYYY-MM-DD day is not carried
   * at all - applying it as "none" would clear a date Salesforce holds on the strength of a value
   * nobody could read - and a buffered log row says which field and what it said.
   */
  private void carryDay(
    InboundChange change,
    Object raw,
    String jiraField,
    Boolean isStart
  ) {
    Date day;
    try {
      day = IsoDate.parseDay(raw);
    } catch (IsoDate.UnreadableDateException e) {
      pendingLogs.add(
        new Integration_Log__c(
          Direction__c = LogDirection.INBOUND,
          Is_Success__c = false,
          Status_Code__c = 0,
          Error_Message__c = Strings.truncate(
            change.externalId +
              ': ' +
              jiraField +
              ' was not applied. ' +
              e.getMessage() +
              ' The date Salesforce holds was left as it was.',
            BODY_MAX
          )
        )
      );
      return;
    }
    if (isStart) {
      change.carryStartDate(day);
    } else {
      change.carryDueDate(day);
    }
  }

  /**
   * Jira's priority onto the change, mapped by id (ADR build-09, decision 2).
   *
   * Three outcomes, and the difference between the last two is the point:
   *
   * - an id a Field_Mapping__mdt row maps is carried as that row's value, and the en dash's row
   *   maps to blank, so choosing it in Jira clears the priority here;
   * - an explicit null is Jira saying the issue has no priority at all, and clears it too;
   * - an id no row maps is NOT carried. The field keeps what it holds and a buffered log row names
   *   the id (decision 4). Clearing would read as "the owner removed the priority", which is not
   *   what happened, and failing would cost the delivery the rest of its change.
   *
   * A priority object with no id is malformed and counts as absent, as a nameless issuetype does.
   */
  private void carryPriority(InboundChange change, Object raw) {
    if (raw == null) {
      change.carryPriority(null);
      return;
    }
    Map<String, Object> priority = asMap(raw);
    String id = priority == null ? null : asString(priority.get('id'));
    if (String.isBlank(id)) {
      return;
    }
    if (
      !FieldMappingService.isMapped(
        ExternalSystem.JIRA,
        FieldMappingService.PRIORITY,
        id
      )
    ) {
      pendingLogs.add(
        new Integration_Log__c(
          Direction__c = LogDirection.INBOUND,
          Is_Success__c = false,
          Status_Code__c = 0,
          Error_Message__c = Strings.truncate(
            (change.externalKey == null ? '' : change.externalKey + ' ') +
              '(' +
              change.externalId +
              '): Jira priority ' +
              id +
              ' ("' +
              asString(priority.get('name')) +
              '") has no Field_Mapping__mdt row of type Priority, so Priority__c was left as ' +
              'it was and the rest of the change applied. Supporting a new priority needs a ' +
              'picklist value and a mapping row.',
            BODY_MAX
          )
        )
      );
      return;
    }
    change.carryPriority(
      FieldMappingService.normalizedFor(
        ExternalSystem.JIRA,
        FieldMappingService.PRIORITY,
        id
      )
    );
  }

  /**
   * Jira's description as plain text.
   *
   * Webhooks send the REST v2 representation, which is a string - wiki markup, stored as it
   * arrives - and the backfill script asks v2 for the same reason. REST v3 sends the Atlassian
   * Document Format tree instead. Should a delivery ever carry that shape, its text is read out
   * a block per line rather than the description quietly stopping syncing.
   */
  @TestVisible
  private static String plainText(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof String) {
      return (String) value;
    }
    Map<String, Object> node = asMap(value);
    return node == null ? String.valueOf(value) : textOf(node);
  }

  private static String textOf(Map<String, Object> node) {
    String type = asString(node.get('type'));
    if (type == 'text') {
      return asString(node.get('text'));
    }
    if (type == 'hardBreak') {
      return '\n';
    }
    List<String> parts = new List<String>();
    Object children = node.get('content');
    if (children instanceof List<Object>) {
      for (Object child : (List<Object>) children) {
        Map<String, Object> childNode = asMap(child);
        String text = childNode == null ? null : textOf(childNode);
        if (text != null) {
          parts.add(text);
        }
      }
    }
    return String.join(parts, INLINE_PARENTS.contains(type) ? '' : '\n');
  }

  /**
   * Jira sends ISO-8601 with a four digit offset (+0000, or the site's local -0700). Insert the
   * colon before handing it to the JSON parser, which wants an RFC-3339 shaped offset.
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

  // ---------- outbound ----------

  /**
   * Push the changed fields, as at most three callouts: one PUT for every field edit, then the
   * two-step transition for a status.
   *
   * Field edits go first. Some Jira workflows make an issue read-only once it is in Done, so an
   * edit sent after a transition into Done could be refused where the same edit sent before it
   * lands. Each part is still attempted whatever the other did, and the result says which ones
   * Jira accepted.
   *
   * Only the changed fields travel, and a cleared date is sent as an explicit null, which is how
   * Jira removes one.
   */
  public SyncResult push(Work_Item__c item, Set<SyncField> changed) {
    SyncResult rejection = validatePush(item, changed);
    if (rejection != null) {
      return rejection;
    }
    String externalId = item.External_Id__c;
    String rawId = ExternalIdUtil.rawIdOf(externalId);

    Set<SyncField> confirmed = new Set<SyncField>();
    SyncResult failure = null;
    Integer lastStatusCode = null;

    Set<SyncField> edits = new Set<SyncField>(changed);
    edits.remove(SyncField.STATUS);
    if (!edits.isEmpty()) {
      Map<String, Object> fields = new Map<String, Object>();
      String unmapped = null;
      if (edits.contains(SyncField.TITLE)) {
        fields.put('summary', item.Title__c);
      }
      if (edits.contains(SyncField.DUE_DATE)) {
        fields.put('duedate', IsoDate.format(item.Due_Date__c));
      }
      if (edits.contains(SyncField.START_DATE)) {
        String startField = startDateFieldId();
        if (startField == null) {
          edits.remove(SyncField.START_DATE);
          unmapped =
            'No Field_Mapping__mdt row of type Field names the Jira field for Start_Date__c, ' +
            'so the start date was not pushed. Add one - on this site it is customfield_10015.';
        } else {
          fields.put(startField, IsoDate.format(item.Start_Date__c));
        }
      }
      if (unmapped != null) {
        failure = SyncResult.failure(
          SyncResult.Outcome.BAD_REQUEST,
          unmapped,
          null
        );
      }
      if (!fields.isEmpty()) {
        SyncResult edited = putFields(item, rawId, fields);
        if (edited == null) {
          confirmed.addAll(edits);
          lastStatusCode = 204;
        } else {
          failure = combine(failure, edited);
        }
      }
    }

    SyncResult moved = null;
    if (changed.contains(SyncField.STATUS)) {
      moved = transition(item, rawId, item.Status__c);
      if (moved.isSuccess()) {
        confirmed.add(SyncField.STATUS);
        lastStatusCode = moved.statusCode;
      } else {
        failure = combine(failure, moved);
      }
    }

    SyncResult result;
    if (failure != null) {
      result = failure;
    } else if (
      edits.isEmpty() &&
      moved != null &&
      moved.outcome == SyncResult.Outcome.ALREADY_IN_TARGET_STATUS
    ) {
      // Nothing was written: the status was all there was, and Jira already had it. Saying
      // "pushed" in the log would claim a change nobody made.
      result = moved;
    } else {
      result = SyncResult.pushed(confirmed, lastStatusCode);
    }
    result.confirmedFields = confirmed;
    return stamp(result, item, externalId);
  }

  /** One PUT carrying every field edit. Null on success; the failure otherwise. */
  private SyncResult putFields(
    Work_Item__c item,
    String rawId,
    Map<String, Object> fields
  ) {
    // Serialized from a map, so a cleared date goes out as "duedate":null rather than being
    // left out, and a title with quotes in it cannot break the body.
    String body = JSON.serialize(new Map<String, Object>{ 'fields' => fields });
    HttpResponse response;
    try {
      response = send('PUT', issuePath(rawId), body, item.Id);
    } catch (Exception e) {
      return SyncResult.failure(
        SyncResult.Outcome.CALLOUT_FAILED,
        Strings.describe(e),
        0
      );
    }
    if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
      return toFailure(
        response,
        'editing ' + String.join(new List<String>(fields.keySet()), ', ')
      );
    }
    return null;
  }

  /**
   * Move the issue to a normalized status: list the transitions reachable from where it is,
   * post the one landing in the target.
   *
   * When none lands there, the issue may simply be there already - which is what moving a card
   * back to the column Jira still has it in looks like after a refused move. One more read tells
   * the two apart, and "already there" counts as done. Without it, a refused move could never be
   * undone from Salesforce: every attempt to put the card back would be refused as well.
   */
  private SyncResult transition(
    Work_Item__c item,
    String rawId,
    String targetStatus
  ) {
    SyncResult rejection = validateStatus(targetStatus);
    if (rejection != null) {
      return rejection;
    }

    HttpResponse listing;
    try {
      listing = send('GET', transitionsPath(rawId), null, item.Id);
    } catch (Exception e) {
      return SyncResult.failure(
        SyncResult.Outcome.CALLOUT_FAILED,
        Strings.describe(e),
        0
      );
    }
    if (listing.getStatusCode() < 200 || listing.getStatusCode() >= 300) {
      return toFailure(listing, 'listing transitions');
    }

    List<TransitionOption> options;
    try {
      options = parseTransitions(listing.getBody());
    } catch (Exception e) {
      return SyncResult.failure(
        SyncResult.Outcome.REMOTE_ERROR,
        'Could not parse the transitions response: ' + Strings.describe(e),
        listing.getStatusCode()
      );
    }

    TransitionOption chosen = match(options, targetStatus);
    if (chosen == null) {
      if (isAlreadyIn(item, rawId, targetStatus)) {
        return SyncResult.alreadyInTargetStatus(targetStatus);
      }
      // Expected answer, not a fault: Jira workflows genuinely forbid some moves. The message
      // names what WAS on offer, because that is how a person fixes it.
      return SyncResult.failure(
        SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
        'Jira will not move this issue to "' +
          targetStatus +
          '" from where it is. Available: ' +
          describeOptions(options) +
          '. Move the card to one of those, or back to where it was.',
        listing.getStatusCode()
      );
    }

    HttpResponse applied;
    try {
      applied = send(
        'POST',
        transitionsPath(rawId),
        transitionPayload(chosen.id),
        item.Id
      );
    } catch (Exception e) {
      return SyncResult.failure(
        SyncResult.Outcome.CALLOUT_FAILED,
        Strings.describe(e),
        0
      );
    }
    if (applied.getStatusCode() < 200 || applied.getStatusCode() >= 300) {
      return toFailure(applied, 'applying transition ' + chosen.id);
    }
    SyncResult done = SyncResult.pushed(
      new Set<SyncField>{ SyncField.STATUS },
      applied.getStatusCode()
    );
    done.appliedStatus = targetStatus;
    return done;
  }

  /**
   * Whether the issue already sits in the target status. False on any doubt - an unreachable
   * Jira, an unreadable body - so doubt reports the refused move rather than inventing success.
   */
  private Boolean isAlreadyIn(
    Work_Item__c item,
    String rawId,
    String targetStatus
  ) {
    try {
      HttpResponse response = send(
        'GET',
        issuePath(rawId) + '?fields=status',
        null,
        item.Id
      );
      if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
        return false;
      }
      Map<String, Object> issue = (Map<String, Object>) JSON.deserializeUntyped(
        response.getBody()
      );
      Map<String, Object> fields = asMap(issue.get('fields'));
      Map<String, Object> status = fields == null
        ? null
        : asMap(fields.get('status'));
      String name = status == null ? null : asString(status.get('name'));
      return String.isNotBlank(name) && normalizeStatus(name) == targetStatus;
    } catch (Exception e) {
      return false;
    }
  }

  /** Two failed parts reported as one, keeping the first part's classification. */
  private static SyncResult combine(SyncResult first, SyncResult second) {
    if (first == null) {
      return second;
    }
    return SyncResult.failure(
      first.outcome,
      first.message + ' Also: ' + second.message,
      first.statusCode
    );
  }

  public List<TransitionOption> fetchAvailableTransitions(String externalId) {
    if (!ExternalIdUtil.belongsTo(externalId, SYSTEM_NAMESPACE)) {
      throw new AdapterException('Not a Jira external id: ' + externalId);
    }

    HttpResponse response;
    try {
      response = send(
        'GET',
        transitionsPath(ExternalIdUtil.rawIdOf(externalId)),
        null,
        null
      );
    } catch (Exception e) {
      throw new AdapterException(
        'Could not reach Jira: ' + Strings.describe(e),
        e
      );
    }
    if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
      throw new AdapterException(
        'Jira returned ' +
          response.getStatusCode() +
          ' listing transitions for ' +
          externalId
      );
    }
    return parseTransitions(response.getBody());
  }

  // ---------- Jira specifics ----------

  private String issuePath(String rawId) {
    return API_BASE + '/issue/' + EncodingUtil.urlEncode(rawId, 'UTF-8');
  }

  private String transitionsPath(String rawId) {
    return issuePath(rawId) + '/transitions';
  }

  private String transitionPayload(String transitionId) {
    return JSON.serialize(
      new Map<String, Object>{
        'transition' => new Map<String, Object>{ 'id' => transitionId }
      }
    );
  }

  /**
   * Reads Jira's transitions envelope. Matching is on to.name - the status the issue LANDS in -
   * not on the transition's own name, which is a button label like "Start Progress".
   */
  private List<TransitionOption> parseTransitions(String body) {
    List<TransitionOption> options = new List<TransitionOption>();
    if (String.isBlank(body)) {
      return options;
    }
    Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(
      body
    );
    Object raw = envelope.get('transitions');
    if (!(raw instanceof List<Object>)) {
      return options;
    }
    for (Object entry : (List<Object>) raw) {
      Map<String, Object> transition = (Map<String, Object>) entry;
      Object target = transition.get('to');
      if (!(target instanceof Map<String, Object>)) {
        continue;
      }
      String targetName = (String) ((Map<String, Object>) target).get('name');
      Object rawTransitionId = transition.get('id');
      // String.valueOf(null) is the literal 'null', which would sail past a blank check.
      String transitionId = rawTransitionId == null
        ? null
        : String.valueOf(rawTransitionId);
      if (String.isNotBlank(transitionId) && String.isNotBlank(targetName)) {
        options.add(new TransitionOption(transitionId, targetName));
      }
    }
    return options;
  }

  /**
   * Picks the transition landing in targetStatus: exact name match first, then the alias table.
   */
  private TransitionOption match(
    List<TransitionOption> options,
    String targetStatus
  ) {
    String wanted = normalize(targetStatus);
    for (TransitionOption option : options) {
      if (normalize(option.targetStatus) == wanted) {
        return option;
      }
    }
    Set<String> aliases = STATUS_ALIASES.get(targetStatus);
    if (aliases != null) {
      for (TransitionOption option : options) {
        if (aliases.contains(normalize(option.targetStatus))) {
          return option;
        }
      }
    }
    return null;
  }

  // ---------- HTTP + logging ----------

  /**
   * Issues one callout and buffers exactly one Integration_Log__c row for it, success or
   * failure. The row is buffered rather than inserted: DML here would break the next callout
   * in the same transaction.
   */
  private HttpResponse send(
    String method,
    String path,
    String body,
    Id workItemId
  ) {
    HttpRequest request = new HttpRequest();
    request.setEndpoint('callout:' + NAMED_CREDENTIAL + path);
    request.setMethod(method);
    request.setTimeout(TIMEOUT_MS);
    request.setHeader('Accept', 'application/json');
    if (body != null) {
      request.setHeader('Content-Type', 'application/json');
      request.setBody(body);
    }

    Long startedAt = System.currentTimeMillis();
    try {
      HttpResponse response = new Http().send(request);
      log(method, path, body, workItemId, startedAt, response, null);
      return response;
    } catch (Exception e) {
      log(method, path, body, workItemId, startedAt, null, e);
      throw e;
    }
  }

  private void log(
    String method,
    String path,
    String body,
    Id workItemId,
    Long startedAt,
    HttpResponse response,
    Exception error
  ) {
    Integer status = response == null ? 0 : response.getStatusCode();
    pendingLogs.add(
      new Integration_Log__c(
        Direction__c = LogDirection.OUTBOUND,
        Endpoint__c = Strings.truncate(
          'callout:' + NAMED_CREDENTIAL + path,
          ENDPOINT_MAX
        ),
        HTTP_Method__c = method,
        Status_Code__c = status,
        Duration_ms__c = System.currentTimeMillis() - startedAt,
        Request_Body__c = Strings.truncate(body, BODY_MAX),
        Response_Body__c = response == null
          ? null
          : Strings.truncate(response.getBody(), BODY_MAX),
        Error_Message__c = error == null
          ? null
          : Strings.truncate(Strings.describe(error), BODY_MAX),
        Work_Item__c = workItemId,
        Is_Success__c = status >= 200 && status < 300
      )
    );
  }

  // ---------- helpers ----------

  private SyncResult validatePush(Work_Item__c item, Set<SyncField> changed) {
    if (item == null) {
      return SyncResult.failure(
        SyncResult.Outcome.BAD_REQUEST,
        'No work item supplied.',
        null
      );
    }
    if (changed == null || changed.isEmpty()) {
      return stamp(SyncResult.nothingToPush(), item, item.External_Id__c);
    }
    if (!ExternalIdUtil.belongsTo(item.External_Id__c, SYSTEM_NAMESPACE)) {
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.BAD_REQUEST,
          'Work item has no usable Jira external id: ' + item.External_Id__c,
          null
        ),
        item,
        item.External_Id__c
      );
    }
    return null;
  }

  private SyncResult validateStatus(String targetStatus) {
    if (String.isBlank(targetStatus)) {
      return SyncResult.failure(
        SyncResult.Outcome.BAD_REQUEST,
        'No target status supplied.',
        null
      );
    }
    if (targetStatus == WorkItemStatus.UNSPECIFIED) {
      return SyncResult.failure(
        SyncResult.Outcome.BAD_REQUEST,
        'Unspecified is a placeholder for an unmapped status and cannot be a transition target.',
        null
      );
    }
    if (!STATUS_ALIASES.containsKey(targetStatus)) {
      return SyncResult.failure(
        SyncResult.Outcome.BAD_REQUEST,
        'Not a recognised Status__c value: ' + targetStatus,
        null
      );
    }
    return null;
  }

  private SyncResult toFailure(HttpResponse response, String phase) {
    Integer status = response.getStatusCode();
    SyncResult.Outcome outcome;
    if (status == 401 || status == 403) {
      outcome = SyncResult.Outcome.UNAUTHORIZED;
    } else if (status == 429) {
      outcome = SyncResult.Outcome.RATE_LIMITED;
    } else {
      outcome = SyncResult.Outcome.REMOTE_ERROR;
    }
    return SyncResult.failure(
      outcome,
      'Jira returned ' +
        status +
        ' ' +
        response.getStatus() +
        ' while ' +
        phase +
        '.',
      status
    );
  }

  private SyncResult stamp(
    SyncResult result,
    Work_Item__c item,
    String externalId
  ) {
    result.workItemId = item == null ? null : item.Id;
    result.externalId = externalId;
    return result;
  }

  private String describeOptions(List<TransitionOption> options) {
    if (options.isEmpty()) {
      return 'none';
    }
    List<String> names = new List<String>();
    for (TransitionOption option : options) {
      names.add(option.targetStatus + ' (id ' + option.id + ')');
    }
    return String.join(names, ', ');
  }

  private static String normalize(String value) {
    return value == null
      ? ''
      : value.trim().toLowerCase().replaceAll('\\s+', ' ');
  }

  private static Map<String, Object> asMap(Object value) {
    return value instanceof Map<String, Object>
      ? (Map<String, Object>) value
      : null;
  }

  private static String asString(Object value) {
    return value == null ? null : String.valueOf(value);
  }
}
