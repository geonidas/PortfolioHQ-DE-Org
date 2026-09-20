/**
 * Jira Cloud implementation of IWorkItemAdapter.
 *
 * Everything Jira-shaped is confined here: the named credential, the /rest/api/3 paths, the
 * response envelope, the webhook payload shape, and the mapping between Jira's workflow status
 * and issue type names and our normalized Work_Item__c values.
 *
 * A status change is two callouts, not one. Jira will not accept a target status directly - you
 * ask which transitions are legal from the issue's current state, then post the id of the one
 * whose TARGET status matches. Transition ids are per-workflow and are never hardcoded.
 *
 * Callout budget: 2 calls per item, against a limit of 100 callouts and 120 seconds of cumulative
 * callout time per transaction. The 120 seconds is the tighter constraint in practice - see
 * WorkItemSyncService for how work is chunked.
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

    change.remoteUpdated = parseIso(asString(fields.get('updated')));
    if (change.remoteUpdated == null) {
      change.failure = 'Payload carries no usable issue.fields.updated timestamp.';
      return change;
    }
    return change;
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

  public SyncResult updateStatus(Work_Item__c item, String targetStatus) {
    SyncResult rejection = validate(item, targetStatus);
    if (rejection != null) {
      return rejection;
    }

    String externalId = item.External_Id__c;
    String rawId = ExternalIdUtil.rawIdOf(externalId);

    // Skip both callouts only when Salesforce already believes the remote agrees: the status
    // matches AND the last sync succeeded. Matching status alone is not enough - the service
    // pushes item.Status__c as its own target, so that test would always pass and nothing
    // would ever sync. Sync_Status__c is what makes the belief credible.
    if (
      normalize(item.Status__c) == normalize(targetStatus) &&
      item.Sync_Status__c == SyncStatus.SYNCED
    ) {
      SyncResult result = SyncResult.alreadyInTargetStatus(targetStatus);
      result.workItemId = item.Id;
      result.externalId = externalId;
      return result;
    }

    HttpResponse listing;
    try {
      listing = send('GET', transitionsPath(rawId), null, item.Id);
    } catch (Exception e) {
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.CALLOUT_FAILED,
          Strings.describe(e),
          0
        ),
        item,
        externalId
      );
    }
    if (listing.getStatusCode() < 200 || listing.getStatusCode() >= 300) {
      return stamp(toFailure(listing, 'listing transitions'), item, externalId);
    }

    List<TransitionOption> options;
    try {
      options = parseTransitions(listing.getBody());
    } catch (Exception e) {
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.REMOTE_ERROR,
          'Could not parse the transitions response: ' + Strings.describe(e),
          listing.getStatusCode()
        ),
        item,
        externalId
      );
    }

    TransitionOption chosen = match(options, targetStatus);
    if (chosen == null) {
      // Expected answer, not a fault: Jira workflows genuinely forbid some moves.
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
          'No transition to "' +
            targetStatus +
            '" is available from the current state. Available: ' +
            describeOptions(options),
          listing.getStatusCode()
        ),
        item,
        externalId
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
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.CALLOUT_FAILED,
          Strings.describe(e),
          0
        ),
        item,
        externalId
      );
    }
    if (applied.getStatusCode() < 200 || applied.getStatusCode() >= 300) {
      return stamp(
        toFailure(applied, 'applying transition ' + chosen.id),
        item,
        externalId
      );
    }

    return stamp(
      SyncResult.success(targetStatus, applied.getStatusCode()),
      item,
      externalId
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

  private String transitionsPath(String rawId) {
    return API_BASE +
      '/issue/' +
      EncodingUtil.urlEncode(rawId, 'UTF-8') +
      '/transitions';
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

  private SyncResult validate(Work_Item__c item, String targetStatus) {
    if (item == null) {
      return SyncResult.failure(
        SyncResult.Outcome.BAD_REQUEST,
        'No work item supplied.',
        null
      );
    }
    if (String.isBlank(targetStatus)) {
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.BAD_REQUEST,
          'No target status supplied.',
          null
        ),
        item,
        item.External_Id__c
      );
    }
    if (targetStatus == WorkItemStatus.UNSPECIFIED) {
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.BAD_REQUEST,
          'Unspecified is a placeholder for an unmapped status and cannot be a transition target.',
          null
        ),
        item,
        item.External_Id__c
      );
    }
    if (!STATUS_ALIASES.containsKey(targetStatus)) {
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.BAD_REQUEST,
          'Not a recognised Status__c value: ' + targetStatus,
          null
        ),
        item,
        item.External_Id__c
      );
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
