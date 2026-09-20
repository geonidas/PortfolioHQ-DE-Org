/**
 * Asana implementation of IWorkItemAdapter.
 *
 * Everything Asana-shaped is confined here: the named credential, the /tasks and /batch paths,
 * the memberships array, the section-gid mapping and the completion flag. Nothing above this
 * class knows any of it, which is the whole reason a second system is a new class rather than a
 * branch in the processor.
 *
 * The difference from Jira that shapes this class: Asana's webhook payloads are THIN. An event
 * names a resource gid and an action and carries nothing else - not the task's name, not its
 * section, not whether it is finished. So parseInbound hydrates: it collects the distinct task
 * gids a delivery batch refers to and fetches them. That is why the interface takes a batch, and
 * it is why NO DML MAY HAVE HAPPENED in the transaction before parseInbound is called - Apex
 * refuses a callout after uncommitted work, and it would refuse it for Asana only, with an error
 * that never mentions Asana.
 *
 * Callout budget: Asana's batch endpoint accepts up to 10 actions per request, so fifty tasks
 * cost five callouts rather than fifty. A delivery that would still exceed the transaction limit
 * is processed as far as it fits and the rest is left staged - the processor leaves a delivery
 * with no change untouched and Pending, so the next run picks it up.
 */
public with sharing class AsanaAdapter implements IWorkItemAdapter {
  @TestVisible
  private static final String NAMED_CREDENTIAL = 'Asana_Personal';
  @TestVisible
  private static final String SYSTEM_NAMESPACE = ExternalSystem.ASANA_NAMESPACE;
  private static final String SOURCE_SYSTEM = ExternalSystem.ASANA;
  private static final Integer TIMEOUT_MS = 20000;

  /** Asana's batch endpoint caps at 10 actions per request. */
  @TestVisible
  private static Integer batchSize = 10;

  /**
   * Asana returns a minimal object unless fields are asked for. Every one of these is needed:
   * without memberships the section is unknowable, and without completed a finished task reads
   * as whatever column it was left in.
   */
  private static final String OPT_FIELDS =
    'name,completed,modified_at,resource_subtype,' +
    'memberships.project.gid,memberships.project.name,' +
    'memberships.section.gid,memberships.section.name,' +
    'custom_fields.name,custom_fields.display_value';

  private static final Integer ENDPOINT_MAX = Integration_Log__c.Endpoint__c.getDescribe()
    .getLength();
  private static final Integer BODY_MAX = Integration_Log__c.Request_Body__c.getDescribe()
    .getLength();
  private static final Integer TITLE_MAX = Work_Item__c.Title__c.getDescribe()
    .getLength();

  /**
   * The name of the Asana custom field that carries a work item's type.
   *
   * Asana has no native type on a task - resource_subtype only distinguishes a task from a
   * milestone - so the learning project carries one in a custom field. Read case-insensitively,
   * and absent is absent: a task with no such field leaves Type__c alone rather than being
   * retyped to Unspecified. See the build 07 report for why this is a convention rather than an
   * API feature.
   */
  private static final String TYPE_CUSTOM_FIELD = 'type';

  private final List<Integration_Log__c> pendingLogs = new List<Integration_Log__c>();

  public List<Integration_Log__c> drainLogs() {
    List<Integration_Log__c> drained = new List<Integration_Log__c>(
      pendingLogs
    );
    pendingLogs.clear();
    return drained;
  }

  // ---------- normalization ----------

  /**
   * A section gid to a Status__c value.
   *
   * Keyed on the gid and never on the section name, because a gid survives a rename and a name
   * does not - and a mapping that silently stopped matching because somebody retitled a column
   * would be invisible until the board went wrong. An unmapped section lands on the same
   * catch-all an unmapped Jira status does.
   */
  public String normalizeStatus(String remoteStatusName) {
    String mapped = FieldMappingService.normalizedFor(
      SOURCE_SYSTEM,
      FieldMappingService.STATUS,
      remoteStatusName
    );
    return mapped == null ? WorkItemStatus.UNSPECIFIED : mapped;
  }

  /** A raw Asana type string to a Type__c value. See step 7 for the promotion path. */
  public String normalizeType(String remoteTypeName) {
    if (String.isBlank(remoteTypeName)) {
      return WorkItemType.UNSPECIFIED;
    }
    String mapped = FieldMappingService.normalizedFor(
      SOURCE_SYSTEM,
      FieldMappingService.TYPE,
      remoteTypeName
    );
    return mapped == null ? WorkItemType.UNSPECIFIED : mapped;
  }

  // ---------- inbound ----------

  public List<InboundChange> parseInbound(List<Webhook_Event__c> events) {
    List<InboundChange> changes = new List<InboundChange>();
    if (events == null || events.isEmpty()) {
      return changes;
    }

    // Which task each delivery is about. Two events on one task in one delivery are one entry
    // in `wanted` and therefore one fetch - deduplication is the reason hydration is affordable.
    //
    // Parallel lists rather than a map keyed on Webhook_Event__c.Id. An Id is not guaranteed to
    // be set - an unsaved row has none - and a map keyed on null silently answers every event
    // with the same task, which is how an unreadable delivery came back carrying another task's
    // change. Position is the honest key here.
    List<Webhook_Event__c> taskEvents = new List<Webhook_Event__c>();
    List<String> gidPerEvent = new List<String>();
    Set<String> wanted = new Set<String>();
    for (Webhook_Event__c event : events) {
      String gid = taskGidFrom(event, changes);
      if (gid == null) {
        continue;
      }
      taskEvents.add(event);
      gidPerEvent.add(gid);
      wanted.add(gid);
    }
    if (wanted.isEmpty()) {
      return changes;
    }

    // Before any callout, and deliberately: this is the only way to know which of a task's
    // memberships is the one we track. Asana puts a task in several projects with a different
    // section in each, so "the section" is meaningless without naming the project first.
    Set<String> knownProjectGids = trackedProjectGids();

    Map<String, Map<String, Object>> tasksByGid = fetch(wanted);

    for (Integer i = 0; i < taskEvents.size(); i++) {
      Webhook_Event__c event = taskEvents[i];
      String gid = gidPerEvent[i];
      Map<String, Object> task = tasksByGid.get(gid);
      if (task == null) {
        // The fetch failed or never ran - budget, or a task the API would not return. The
        // delivery is left with no change at all, which the processor reads as "leave it
        // staged", so the next run tries again rather than retiring it wrongly.
        continue;
      }
      changes.add(toChange(event, gid, task, knownProjectGids));
    }
    return changes;
  }

  /**
   * One hydrated task to a vendor-neutral change.
   *
   * The completion flag overrides the section, and that asymmetry is the point rather than an
   * edge case. Asana's completion checkbox is independent of sections and is the easiest way in
   * the UI to finish something: it sets completed true without moving the card. Without this
   * rule, ticking the box strikes the task through in Asana while the Salesforce board still
   * shows In Progress, and nothing anywhere says why.
   */
  private InboundChange toChange(
    Webhook_Event__c event,
    String gid,
    Map<String, Object> task,
    Set<String> knownProjectGids
  ) {
    InboundChange change = new InboundChange();
    change.sourceEventId = event.Id;
    change.eventType = eventActionFrom(event);
    change.externalId = ExternalIdUtil.qualify(SYSTEM_NAMESPACE, gid);
    // Asana has no human-readable key. There is no equivalent of DOPP-42 to display, so the
    // card shows a title and nothing else, and External_Key__c stays null rather than being
    // filled with the gid a visitor cannot use.
    change.externalKey = null;

    change.title = Strings.truncate(asString(task.get('name')), TITLE_MAX);

    change.remoteUpdated = parseIso(asString(task.get('modified_at')));
    if (change.remoteUpdated == null) {
      change.failure =
        'Task ' +
        gid +
        ' carries no usable modified_at timestamp.';
      log(
        'Delivery for task ' +
          gid +
          ' could not be applied: no usable modified_at. Asana always sends one, so this is ' +
          'a shape change or a truncated response.'
      );
      return change;
    }

    // The membership for the project we track, and only that one. A task in two projects has a
    // different section in each; reading task.section, or the first membership, would take
    // whichever Asana happened to list first.
    Map<String, Object> membership = membershipFor(task, knownProjectGids);
    String sectionGid = null;
    if (membership != null) {
      Map<String, Object> project = asMap(membership.get('project'));
      change.projectKey = project == null ? null : asString(project.get('gid'));
      Map<String, Object> section = asMap(membership.get('section'));
      if (section != null) {
        sectionGid = asString(section.get('gid'));
        change.remoteStatus = asString(section.get('name'));
      }
    } else {
      log(
        'Task ' +
          gid +
          ' is in no project this org tracks, so it has no section to read a status from and ' +
          'no project to link to. Create a Project__c with External_Project_Key__c set to the ' +
          'Asana project gid and External_System__c = Asana, then change the task again.'
      );
    }

    Boolean completed = task.get('completed') == true;
    if (completed) {
      // Whatever the section says. See the method comment.
      change.normalizedStatus = WorkItemStatus.DONE;
      if (String.isBlank(change.remoteStatus)) {
        change.remoteStatus = 'completed';
      }
    } else {
      change.normalizedStatus = normalizeStatus(sectionGid);
      if (
        change.normalizedStatus == WorkItemStatus.UNSPECIFIED &&
        String.isNotBlank(sectionGid)
      ) {
        log(
          'Section ' +
            sectionGid +
            ' ("' +
            (change.remoteStatus == null ? '' : change.remoteStatus) +
            '") on task ' +
            gid +
            ' has no Field_Mapping__mdt row, so Status__c is Unspecified. Add a Status mapping ' +
            'keyed on the section GID - not its name, which changes.'
        );
      }
    }

    // Step 7: the raw vendor string is kept whatever happens to the normalized one, and a type
    // that is absent or blank is absent, never unmapped.
    String rawType = rawTypeFrom(task);
    if (String.isNotBlank(rawType)) {
      change.remoteType = rawType;
      change.normalizedType = normalizeType(rawType);
    }

    // Asana items are flat in this build: no parents, no sub-tasks, no epic equivalent.
    change.parentExternalId = null;
    // Asana has no sprints and never will. The field exists for Jira to fill later.
    change.iterationRef = null;
    return change;
  }

  /** The membership whose project this org tracks, or null when none of them is. */
  private Map<String, Object> membershipFor(
    Map<String, Object> task,
    Set<String> knownProjectGids
  ) {
    Object raw = task.get('memberships');
    if (!(raw instanceof List<Object>)) {
      return null;
    }
    for (Object entry : (List<Object>) raw) {
      Map<String, Object> membership = asMap(entry);
      if (membership == null) {
        continue;
      }
      Map<String, Object> project = asMap(membership.get('project'));
      String projectGid = project == null ? null : asString(project.get('gid'));
      if (
        String.isNotBlank(projectGid) && knownProjectGids.contains(projectGid)
      ) {
        return membership;
      }
    }
    return null;
  }

  /**
   * The raw type string, from a custom field named "Type".
   *
   * resource_subtype is the fallback and is nearly always default_task, which maps to nothing -
   * so in practice a task with no Type custom field carries no type, and the processor leaves
   * Type__c alone. That is build 06's rule: present but blank counts as absent, not unmapped.
   */
  private String rawTypeFrom(Map<String, Object> task) {
    Object raw = task.get('custom_fields');
    if (raw instanceof List<Object>) {
      for (Object entry : (List<Object>) raw) {
        Map<String, Object> field = asMap(entry);
        if (field == null) {
          continue;
        }
        String name = asString(field.get('name'));
        if (
          String.isNotBlank(name) &&
          name.trim().toLowerCase() == TYPE_CUSTOM_FIELD
        ) {
          String value = asString(field.get('display_value'));
          return String.isBlank(value) ? null : value.trim();
        }
      }
    }
    String subtype = asString(task.get('resource_subtype'));
    return subtype == 'default_task' ? null : subtype;
  }

  // ---------- hydration ----------

  /**
   * Fetch the tasks a batch refers to, ten at a time.
   *
   * A request that fails leaves its tasks out of the map, and every event about them is left
   * unparsed and logged rather than failed - the processor leaves those deliveries staged. One
   * failed batch therefore costs ten tasks a cycle, not the whole delivery.
   */
  private Map<String, Map<String, Object>> fetch(Set<String> gids) {
    Map<String, Map<String, Object>> tasksByGid = new Map<String, Map<String, Object>>();
    List<String> pending = new List<String>(gids);

    for (Integer start = 0; start < pending.size(); start += batchSize) {
      if (Limits.getLimitCallouts() - Limits.getCallouts() < 1) {
        log(
          'Callout limit reached with ' +
            (pending.size() - start) +
            ' task(s) still to fetch. Their deliveries were left staged and will be picked up ' +
            'on the next run rather than failed.'
        );
        break;
      }
      List<String> slice = new List<String>();
      for (
        Integer i = start; i < pending.size() && i < start + batchSize; i++
      ) {
        slice.add(pending[i]);
      }
      fetchSlice(slice, tasksByGid);
    }
    return tasksByGid;
  }

  private void fetchSlice(
    List<String> gids,
    Map<String, Map<String, Object>> collected
  ) {
    List<Object> actions = new List<Object>();
    for (String gid : gids) {
      actions.add(
        new Map<String, Object>{
          'method' => 'get',
          'relative_path' => '/tasks/' +
          EncodingUtil.urlEncode(gid, 'UTF-8') +
          '?opt_fields=' +
          OPT_FIELDS
        }
      );
    }
    String body = JSON.serialize(
      new Map<String, Object>{
        'data' => new Map<String, Object>{ 'actions' => actions }
      }
    );

    HttpResponse response;
    try {
      response = send('POST', '/batch', body);
    } catch (Exception e) {
      log(
        'Could not fetch ' +
          gids.size() +
          ' task(s) from Asana: ' +
          Strings.describe(e) +
          '. Their deliveries were left staged.'
      );
      return;
    }
    if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
      log(
        'Asana returned ' +
          response.getStatusCode() +
          ' fetching ' +
          gids.size() +
          ' task(s). Their deliveries were left staged.'
      );
      return;
    }

    try {
      readBatch(response.getBody(), collected);
    } catch (Exception e) {
      log(
        'Could not read Asana\'s batch response: ' +
          Strings.describe(e) +
          '. The deliveries it covered were left staged.'
      );
    }
  }

  /**
   * Asana's batch envelope: data is an array of per-action results, each with its own
   * status_code and its own body carrying the usual { "data": { ... } } wrapper. A single action
   * failing inside an otherwise 200 response is normal and costs only that task.
   */
  private void readBatch(
    String responseBody,
    Map<String, Map<String, Object>> collected
  ) {
    if (String.isBlank(responseBody)) {
      return;
    }
    Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(
      responseBody
    );
    Object raw = envelope.get('data');
    if (!(raw instanceof List<Object>)) {
      return;
    }
    for (Object entry : (List<Object>) raw) {
      Map<String, Object> result = asMap(entry);
      if (result == null) {
        continue;
      }
      Object status = result.get('status_code');
      if (!(status instanceof Integer) || (Integer) status != 200) {
        log(
          'One task in a batch came back ' +
            String.valueOf(status) +
            '. Its delivery was left staged.'
        );
        continue;
      }
      Map<String, Object> resultBody = asMap(result.get('body'));
      Map<String, Object> task = resultBody == null
        ? null
        : asMap(resultBody.get('data'));
      String gid = task == null ? null : asString(task.get('gid'));
      if (String.isNotBlank(gid)) {
        collected.put(gid, task);
      }
    }
  }

  // Tests that exercise hydration cannot query for these: inserting a Project__c is DML, and
  // DML before a callout throws. Injection keeps the callout tests honest about everything
  // else; theQueryForTrackedProjectsReadsRealRecords covers the query itself, without a callout.
  @TestVisible
  private static Set<String> injectedProjectGids;

  /** Project gids this org tracks, one query whatever the batch size. */
  private Set<String> trackedProjectGids() {
    if (injectedProjectGids != null) {
      return injectedProjectGids;
    }
    Set<String> gids = new Set<String>();
    for (Project__c project : [
      SELECT External_Project_Key__c
      FROM Project__c
      WHERE
        External_System__c = :SOURCE_SYSTEM
        AND External_Project_Key__c != NULL
    ]) {
      gids.add(project.External_Project_Key__c.trim());
    }
    return gids;
  }

  // ---------- reading the event ----------

  /**
   * The task gid an event is about, or null when the event is not about a task.
   *
   * Asana sends events for sections, projects and stories on the same webhook. Anything that is
   * not a task is not this integration's business: no change is returned for it, so the
   * processor leaves the row staged rather than failing it - and a later build that does care
   * about sections can pick it up without a redelivery.
   */
  private String taskGidFrom(
    Webhook_Event__c event,
    List<InboundChange> changes
  ) {
    if (String.isBlank(event.Raw_Payload__c)) {
      InboundChange change = new InboundChange();
      change.sourceEventId = event.Id;
      change.failure = 'Empty payload.';
      changes.add(change);
      return null;
    }
    Map<String, Object> payload;
    try {
      payload = (Map<String, Object>) JSON.deserializeUntyped(
        event.Raw_Payload__c
      );
    } catch (Exception e) {
      InboundChange change = new InboundChange();
      change.sourceEventId = event.Id;
      change.failure = 'Malformed JSON: ' + Strings.describe(e);
      changes.add(change);
      log('An Asana event could not be read: ' + Strings.describe(e));
      return null;
    }
    Map<String, Object> resource = asMap(payload.get('resource'));
    if (resource == null) {
      InboundChange change = new InboundChange();
      change.sourceEventId = event.Id;
      change.failure = 'Event carries no resource object.';
      changes.add(change);
      return null;
    }
    String resourceType = asString(resource.get('resource_type'));
    if (resourceType != null && resourceType != 'task') {
      // Not a failure and not a change. Left staged on purpose.
      return null;
    }
    String gid = asString(resource.get('gid'));
    return String.isBlank(gid) ? null : gid;
  }

  private String eventActionFrom(Webhook_Event__c event) {
    try {
      Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
        event.Raw_Payload__c
      );
      String action = asString(payload.get('action'));
      return action == null ? null : 'asana:' + action;
    } catch (Exception e) {
      return null;
    }
  }

  // ---------- outbound ----------

  /**
   * Push a status change to Asana, as TWO writes that must both happen.
   *
   * Asana models a board column and a completion checkbox as independent things, and step 6
   * exists to absorb the contradiction that creates on the way in. Writing only one of them on
   * the way out would author exactly that contradiction ourselves:
   *
   *   to Done     move the task to the Completed section AND set completed true
   *   out of Done move it to the target section AND set completed false
   *
   * Writing only the section move to Done leaves a task sitting in Completed that Asana does not
   * consider finished. Writing only the flag leaves a struck-through task in the In Progress
   * column. Both are states a person would have to reconcile by hand.
   *
   * Two callouts per item, the same budget as Jira, so WorkItemSyncService's chunking needs no
   * change. Never throws for a business outcome: an unmapped target status comes back as a
   * result, because a status this org cannot express in Asana is a configuration gap rather
   * than a fault.
   */
  public SyncResult updateStatus(Work_Item__c item, String targetStatus) {
    SyncResult rejection = validate(item, targetStatus);
    if (rejection != null) {
      return rejection;
    }

    String externalId = item.External_Id__c;
    String rawId = ExternalIdUtil.rawIdOf(externalId);
    Boolean toDone = targetStatus == WorkItemStatus.DONE;

    // Resolved BEFORE any callout, so an unmapped status costs nothing. The same
    // Field_Mapping__mdt rows step 6 reads on the way in, read in the other direction.
    String sectionGid = FieldMappingService.externalValueFor(
      SOURCE_SYSTEM,
      FieldMappingService.STATUS,
      targetStatus
    );
    if (String.isBlank(sectionGid)) {
      log(
        'No Asana section is mapped to "' +
          targetStatus +
          '", so ' +
          externalId +
          ' was not pushed. Add a Status Field_Mapping__mdt row keyed on the section gid, or ' +
          'check whether two sections both claim that status - an ambiguous reverse mapping ' +
          'resolves to nothing rather than guessing which column to move work to.'
      );
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
          'No Asana section is mapped to "' + targetStatus + '".',
          null
        ),
        item,
        externalId
      );
    }

    // The section move first. If the second write fails the task is at least in the right
    // column, which is the half a person can see on the board.
    HttpResponse moved;
    try {
      moved = send(
        'POST',
        '/sections/' + EncodingUtil.urlEncode(sectionGid, 'UTF-8') + '/addTask',
        JSON.serialize(
          new Map<String, Object>{
            'data' => new Map<String, Object>{ 'task' => rawId }
          }
        )
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
    if (moved.getStatusCode() < 200 || moved.getStatusCode() >= 300) {
      return stamp(
        toFailure(moved, 'moving the task to section ' + sectionGid),
        item,
        externalId
      );
    }

    HttpResponse flagged;
    try {
      flagged = send(
        'PUT',
        '/tasks/' + EncodingUtil.urlEncode(rawId, 'UTF-8'),
        JSON.serialize(
          new Map<String, Object>{
            'data' => new Map<String, Object>{ 'completed' => toDone }
          }
        )
      );
    } catch (Exception e) {
      return stamp(
        SyncResult.failure(
          SyncResult.Outcome.CALLOUT_FAILED,
          'The section move succeeded but the completion flag did not: ' +
          Strings.describe(e),
          0
        ),
        item,
        externalId
      );
    }
    if (flagged.getStatusCode() < 200 || flagged.getStatusCode() >= 300) {
      return stamp(
        toFailure(
          flagged,
          'setting completed=' +
            toDone +
            ' after moving the task to section ' +
            sectionGid
        ),
        item,
        externalId
      );
    }

    return stamp(
      SyncResult.success(targetStatus, flagged.getStatusCode()),
      item,
      externalId
    );
  }

  public List<TransitionOption> fetchAvailableTransitions(String externalId) {
    if (!ExternalIdUtil.belongsTo(externalId, SYSTEM_NAMESPACE)) {
      throw new AdapterException('Not an Asana external id: ' + externalId);
    }
    // Asana has no workflow to ask. Every mapped section is reachable from every other one -
    // moving a task between columns is never refused - so the answer is the mapping table
    // rather than a callout, and it does not depend on the task at all.
    List<TransitionOption> options = new List<TransitionOption>();
    for (String status : REACHABLE_STATUSES) {
      String sectionGid = FieldMappingService.externalValueFor(
        SOURCE_SYSTEM,
        FieldMappingService.STATUS,
        status
      );
      if (String.isNotBlank(sectionGid)) {
        options.add(new TransitionOption(sectionGid, status));
      }
    }
    return options;
  }

  /** Every Status__c an Asana task can be pushed to. Unspecified is never one of them. */
  private static final List<String> REACHABLE_STATUSES = new List<String>{
    WorkItemStatus.TO_DO,
    WorkItemStatus.IN_PROGRESS,
    WorkItemStatus.IN_REVIEW,
    WorkItemStatus.DONE
  };

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
          'Unspecified is a placeholder for an unmapped status and cannot be a push target.',
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
          'Work item has no usable Asana external id: ' + item.External_Id__c,
          null
        ),
        item,
        item.External_Id__c
      );
    }
    // Deliberately no "already in the target status" short circuit. Jira has one because its
    // first leg is a read that would otherwise be wasted; here both legs are writes, and
    // re-asserting a section and a flag is idempotent and cheap. Skipping on Sync_Status__c
    // alone would also leave the completion flag unrepaired after a partial failure.
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
      'Asana returned ' +
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

  // ---------- HTTP + logging ----------

  private HttpResponse send(String method, String path, String body) {
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
      logCallout(method, path, body, startedAt, response, null);
      return response;
    } catch (Exception e) {
      logCallout(method, path, body, startedAt, null, e);
      throw e;
    }
  }

  private void logCallout(
    String method,
    String path,
    String body,
    Long startedAt,
    HttpResponse response,
    Exception error
  ) {
    Integer status = response == null ? 0 : response.getStatusCode();
    // A GET on /batch is hydration for an inbound delivery; everything else this class sends is
    // a push. The direction is what makes an Integration_Log__c row legible after the fact.
    Boolean isHydration = path == '/batch';
    pendingLogs.add(
      new Integration_Log__c(
        Direction__c = isHydration
          ? LogDirection.INBOUND
          : LogDirection.OUTBOUND,
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
        Is_Success__c = status >= 200 && status < 300
      )
    );
  }

  /** A processing note, not a callout. Buffered like everything else: DML here breaks the next
   * callout in the transaction. */
  private void log(String message) {
    pendingLogs.add(
      new Integration_Log__c(
        Direction__c = LogDirection.INBOUND,
        Is_Success__c = false,
        Status_Code__c = 0,
        Error_Message__c = Strings.truncate(message, BODY_MAX)
      )
    );
  }

  // ---------- helpers ----------

  /** Asana sends RFC-3339 with a Z or a colon-bearing offset, which the JSON parser accepts. */
  @TestVisible
  private static Datetime parseIso(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    try {
      return (Datetime) JSON.deserialize(
        '"' + value.trim() + '"',
        Datetime.class
      );
    } catch (Exception e) {
      return null;
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
}
