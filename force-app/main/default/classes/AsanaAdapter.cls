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
   *
   * A LIST, sent as options.fields on each batch action - not a comma-separated opt_fields query
   * string. Asana refuses a query string inside a batch action with "Parameters are not accepted
   * in a batch action's path", and it refuses it as a 400 INSIDE an otherwise 200 response, so
   * the batch call itself looks like it worked. Found against the live API: the mock had been
   * reading the gid out of the path and answering happily whatever else was in it.
   */
  //
  // created_at, due_on and notes joined in build 08. start_on is absent on purpose and must stay
  // absent: start dates are a paid Asana feature this workspace does not have, Board_Source__mdt
  // says Asana does not support them, and a start date read in here would be one Salesforce then
  // refuses to push back. AsanaAdapterTest fails if it appears.
  @TestVisible
  private static final List<String> OPT_FIELDS = new List<String>{
    'name',
    'completed',
    'modified_at',
    'created_at',
    'due_on',
    'notes',
    'resource_subtype',
    'memberships.project.gid',
    'memberships.project.name',
    'memberships.section.gid',
    'memberships.section.name',
    // The field's own gid, which is how the Priority field is found (build 09) - by gid, like
    // everything else here, never by its name.
    'custom_fields.gid',
    'custom_fields.name',
    'custom_fields.display_value',
    // The chosen enum option's gid, which is what Type and Priority mappings are keyed on.
    'custom_fields.enum_value.gid'
  };

  private static final Integer ENDPOINT_MAX = Integration_Log__c.Endpoint__c.getDescribe()
    .getLength();
  private static final Integer BODY_MAX = Integration_Log__c.Request_Body__c.getDescribe()
    .getLength();
  private static final Integer TITLE_MAX = Work_Item__c.Title__c.getDescribe()
    .getLength();
  private static final Integer DESCRIPTION_MAX = Work_Item__c.Description__c.getDescribe()
    .getLength();

  /**
   * The Asana custom field that carries what kind of work a task is.
   *
   * Asana has no native type on a task - resource_subtype only distinguishes a task from a
   * milestone - so the learning project carries an enum custom field called Format, whose
   * options are Book, Online course, Article / paper and so on. Matched case-insensitively, and
   * absent is absent: a task with no Format leaves Type__c alone rather than being retyped to
   * Unspecified. This is a convention this project chose, not an API feature; the handoff says
   * so where the manual setup is described.
   */
  private static final String TYPE_CUSTOM_FIELD = 'format';

  /** The Work_Item__c field a Field row names to say which Asana custom field is the priority. */
  private static final String PRIORITY_FIELD = String.valueOf(
    Work_Item__c.Priority__c
  );

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

    change.sourceCreated = parseIso(asString(task.get('created_at')));

    // The fetch asks for due_on and notes by name, so Asana answers with the key either way, and
    // a null or empty value means the task has none - which has to clear what Salesforce holds.
    // due_at, a due TIME, is not read: the board works in calendar days.
    if (task.containsKey('due_on')) {
      try {
        change.carryDueDate(IsoDate.parseDay(task.get('due_on')));
      } catch (IsoDate.UnreadableDateException e) {
        log(
          'Task ' +
            gid +
            ': due_on was not applied. ' +
            e.getMessage() +
            ' The date Salesforce holds was left as it was.'
        );
      }
    }
    if (task.containsKey('notes')) {
      change.carryDescription(
        Strings.truncate(asString(task.get('notes')), DESCRIPTION_MAX)
      );
    }
    // No start date, ever - see OPT_FIELDS. carriesStartDate stays false, so the processor
    // never touches Start_Date__c on an Asana item.

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
    // that is absent or blank is absent, never unmapped. The mapping is looked up on the enum
    // option gid; Source_Type__c gets the name a person would recognise.
    RawType rawType = rawTypeFrom(task);
    if (rawType != null) {
      change.remoteType = rawType.display;
      change.normalizedType = normalizeType(rawType.matchOn);
      if (
        change.normalizedType == WorkItemType.UNSPECIFIED &&
        String.isNotBlank(rawType.matchOn)
      ) {
        log(
          'Format "' +
            rawType.display +
            '" (' +
            rawType.matchOn +
            ') on task ' +
            gid +
            ' has no Field_Mapping__mdt row, so Type__c is Unspecified. Source_Type__c keeps ' +
            'the raw value - query it grouped to see which formats are worth mapping.'
        );
      }
    }

    carryPriority(change, task, gid);

    // Asana items are flat in this build: no parents, no sub-tasks, no epic equivalent.
    change.parentExternalId = null;
    // Asana has no sprints and never will. The field exists for Jira to fill later.
    change.iterationRef = null;
    return change;
  }

  /**
   * The task's Priority field onto the change, mapped by option gid (ADR build-09, decisions 1-4).
   *
   * The field is found by its own gid, from a Field_Mapping__mdt row of type Field - the name
   * "Priority" is somebody's label and can change. Then:
   *
   * - no row naming the field, or the field not on the task (its project does not have it): not
   *   carried, and Priority__c is left alone;
   * - the field on the task with no option chosen: Asana's own "none", carried as blank. No
   *   mapping row says this - an empty enum is how Asana spells none, which is this class's
   *   business and no table's;
   * - an option a Priority row maps: carried as that value;
   * - an option no row maps: not carried, and a buffered log row names the gid (decision 4).
   */
  private void carryPriority(
    InboundChange change,
    Map<String, Object> task,
    String taskGid
  ) {
    String fieldGid = FieldMappingService.externalValueFor(
      SOURCE_SYSTEM,
      FieldMappingService.FIELD,
      PRIORITY_FIELD
    );
    Object raw = task.get('custom_fields');
    if (String.isBlank(fieldGid) || !(raw instanceof List<Object>)) {
      return;
    }
    for (Object entry : (List<Object>) raw) {
      Map<String, Object> field = asMap(entry);
      if (
        field == null ||
        asString(field.get('gid')) != fieldGid.trim() ||
        !field.containsKey('enum_value')
      ) {
        continue;
      }
      Map<String, Object> chosen = asMap(field.get('enum_value'));
      if (chosen == null) {
        change.carryPriority(null);
        return;
      }
      String optionGid = asString(chosen.get('gid'));
      if (String.isBlank(optionGid)) {
        // An option with no gid is a shape we did not ask for. Absent, not none.
        return;
      }
      if (
        !FieldMappingService.isMapped(
          SOURCE_SYSTEM,
          FieldMappingService.PRIORITY,
          optionGid
        )
      ) {
        log(
          'Priority option ' +
            optionGid +
            ' ("' +
            asString(field.get('display_value')) +
            '") on task ' +
            taskGid +
            ' has no Field_Mapping__mdt row of type Priority, so Priority__c was left as it ' +
            'was and the rest of the change applied. Supporting a new priority needs a ' +
            'picklist value and a mapping row keyed on the option gid.'
        );
        return;
      }
      change.carryPriority(
        FieldMappingService.normalizedFor(
          SOURCE_SYSTEM,
          FieldMappingService.PRIORITY,
          optionGid
        )
      );
      return;
    }
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
   * What a task's Format field says, as a gid to match on and a name to keep.
   *
   * Two values, because they serve different purposes and the difference is load-bearing:
   *
   * - the enum OPTION GID is what the mapping is keyed on, for the same reason section mappings
   *   are: a gid survives a rename and a name does not, and a mapping that silently stopped
   *   matching because somebody retitled "Online course" would be invisible until the board
   *   went wrong;
   * - the display NAME is what Source_Type__c keeps, because a gid in that field would tell a
   *   person reading the promotion query nothing at all.
   *
   * resource_subtype is the fallback and is nearly always default_task, which maps to nothing -
   * so in practice a task with no Format carries no type, and the processor leaves Type__c
   * alone. That is build 06's rule: present but blank counts as absent, not unmapped.
   */
  private class RawType {
    String matchOn; // enum option gid, or the subtype when there is no Format
    String display; // what a person would call it
  }

  private RawType rawTypeFrom(Map<String, Object> task) {
    Object raw = task.get('custom_fields');
    if (raw instanceof List<Object>) {
      for (Object entry : (List<Object>) raw) {
        Map<String, Object> field = asMap(entry);
        if (field == null) {
          continue;
        }
        String name = asString(field.get('name'));
        if (
          String.isBlank(name) || name.trim().toLowerCase() != TYPE_CUSTOM_FIELD
        ) {
          continue;
        }
        String display = asString(field.get('display_value'));
        if (String.isBlank(display)) {
          // The field is on the task but nobody set it. Absent, not unmapped.
          return null;
        }
        RawType found = new RawType();
        found.display = display.trim();
        Map<String, Object> chosen = asMap(field.get('enum_value'));
        String optionGid = chosen == null ? null : asString(chosen.get('gid'));
        // Falling back to the display name keeps a non-enum Format field usable; it simply
        // loses the rename-safety a gid gives.
        found.matchOn = String.isBlank(optionGid) ? found.display : optionGid;
        return found;
      }
    }
    String subtype = asString(task.get('resource_subtype'));
    if (subtype == null || subtype == 'default_task') {
      return null;
    }
    RawType fromSubtype = new RawType();
    fromSubtype.matchOn = subtype;
    fromSubtype.display = subtype;
    return fromSubtype;
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
          // No query string here: Asana rejects one per action, as a 400 inside a 200.
          'relative_path' => '/tasks/' + gid,
          'options' => new Map<String, Object>{ 'fields' => OPT_FIELDS }
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
   * Push the changed fields to Asana: at most TWO writes, a section move and one task update.
   *
   * A status change is two writes that must both happen. Asana models a board column and a
   * completion checkbox as independent things, and step 6 exists to absorb the contradiction
   * that creates on the way in. Writing only one of them on the way out would author exactly
   * that contradiction ourselves:
   *
   *   to Done     move the task to the Completed section AND set completed true
   *   out of Done move it to the target section AND set completed false
   *
   * Title, due date and priority ride on the same task update as the completion flag - name,
   * due_on and custom_fields - so a status change plus an edit is still two callouts. Writing due_on clears any due TIME
   * the task had (due_at): the board works in calendar days, and Asana holds one or the other.
   *
   * Never start_on. Start dates are a paid Asana feature this workspace does not have, and
   * Board_Source__mdt says so; a start date asked for here is refused as a bad request without a
   * callout, while clearing one - there never is one to clear - counts as done.
   *
   * Never throws for a business outcome: an unmapped target status comes back as a result,
   * because a status this org cannot express in Asana is a configuration gap, not a fault.
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
    Map<String, Object> taskUpdate = new Map<String, Object>();
    Set<SyncField> riding = new Set<SyncField>();

    if (changed.contains(SyncField.START_DATE)) {
      if (item.Start_Date__c == null) {
        // Salesforce never sent Asana a start date, so there is none to clear.
        confirmed.add(SyncField.START_DATE);
      } else {
        failure = SyncResult.failure(
          SyncResult.Outcome.BAD_REQUEST,
          'Asana does not support start dates here, so the start date was not pushed.',
          null
        );
      }
    }
    if (changed.contains(SyncField.TITLE)) {
      taskUpdate.put('name', item.Title__c);
      riding.add(SyncField.TITLE);
    }
    if (changed.contains(SyncField.DUE_DATE)) {
      taskUpdate.put('due_on', IsoDate.format(item.Due_Date__c));
      riding.add(SyncField.DUE_DATE);
    }
    if (changed.contains(SyncField.PRIORITY)) {
      SyncResult priorityRejection = addPriority(item, taskUpdate);
      if (priorityRejection == null) {
        riding.add(SyncField.PRIORITY);
      } else {
        failure = combine(failure, priorityRejection);
      }
    }

    String sectionGid = null;
    if (changed.contains(SyncField.STATUS)) {
      SyncResult statusRejection = validateStatus(item.Status__c);
      if (statusRejection == null) {
        // Resolved BEFORE any callout, so an unmapped status costs nothing. The same
        // Field_Mapping__mdt rows step 6 reads on the way in, read in the other direction.
        sectionGid = FieldMappingService.externalValueFor(
          SOURCE_SYSTEM,
          FieldMappingService.STATUS,
          item.Status__c
        );
        if (String.isBlank(sectionGid)) {
          log(
            'No Asana section is mapped to "' +
              item.Status__c +
              '", so the status of ' +
              externalId +
              ' was not pushed. Add a Status Field_Mapping__mdt row keyed on the section gid, ' +
              'or check whether two sections both claim that status - an ambiguous reverse ' +
              'mapping resolves to nothing rather than guessing which column to move work to.'
          );
          statusRejection = SyncResult.failure(
            SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
            'No Asana section is mapped to "' + item.Status__c + '".',
            null
          );
        }
      }
      if (statusRejection != null) {
        failure = combine(failure, statusRejection);
        sectionGid = null;
      }
    }

    // The section move first. If the task update then fails, the task is at least in the right
    // column, which is the half a person can see on the board.
    if (sectionGid != null) {
      SyncResult moved = moveToSection(rawId, sectionGid);
      if (moved == null) {
        taskUpdate.put('completed', item.Status__c == WorkItemStatus.DONE);
        riding.add(SyncField.STATUS);
      } else {
        // The flag is not written after a failed move: ticking completed on a task still in
        // In Progress would author the contradiction rather than avoid it.
        failure = combine(failure, moved);
      }
    }

    Integer statusCode = null;
    Datetime modifiedAt = null;
    if (!taskUpdate.isEmpty()) {
      HttpResponse updated;
      String phase = describeUpdate(taskUpdate, sectionGid);
      try {
        // modified_at comes back on the same call, so the write-back can stamp Asana's own time
        // for what was just written (SyncResult.remoteUpdated) without a second callout.
        updated = send(
          'PUT',
          '/tasks/' +
            EncodingUtil.urlEncode(rawId, 'UTF-8') +
            '?opt_fields=modified_at',
          JSON.serialize(new Map<String, Object>{ 'data' => taskUpdate })
        );
      } catch (Exception e) {
        updated = null;
        failure = combine(
          failure,
          SyncResult.failure(
            SyncResult.Outcome.CALLOUT_FAILED,
            phase + ' failed: ' + Strings.describe(e),
            0
          )
        );
      }
      if (updated != null) {
        if (updated.getStatusCode() >= 200 && updated.getStatusCode() < 300) {
          confirmed.addAll(riding);
          statusCode = updated.getStatusCode();
          modifiedAt = modifiedAtOf(updated);
        } else {
          failure = combine(failure, toFailure(updated, phase));
        }
      }
    }

    SyncResult result = failure == null
      ? SyncResult.pushed(confirmed, statusCode)
      : failure;
    result.confirmedFields = confirmed;
    result.remoteUpdated = modifiedAt;
    return stamp(result, item, externalId);
  }

  /**
   * Asana's modified_at from a task update's response, or null. Asana hydrates every inbound
   * event with the task as it is NOW, so a late echo already carries current values here; the
   * stamp keeps the two adapters' contracts the same at no cost.
   */
  private static Datetime modifiedAtOf(HttpResponse response) {
    try {
      Map<String, Object> body = asMap(
        JSON.deserializeUntyped(response.getBody())
      );
      Map<String, Object> data = body == null ? null : asMap(body.get('data'));
      return data == null ? null : parseIso(asString(data.get('modified_at')));
    } catch (Exception e) {
      return null;
    }
  }

  /**
   * The priority onto the task update, resolved before any callout (build 09).
   *
   * custom_fields keyed on the Priority field's gid, from its Field row, valued with the option
   * gid a Priority row gives - or null for a blank priority, which is how Asana empties an enum
   * field and is Asana's none. That last part is this class's knowledge, not the mapping table's:
   * no row says "blank". A missing row refuses the priority alone, and the rest of the update
   * still goes. Null on success.
   */
  private SyncResult addPriority(
    Work_Item__c item,
    Map<String, Object> taskUpdate
  ) {
    String fieldGid = FieldMappingService.externalValueFor(
      SOURCE_SYSTEM,
      FieldMappingService.FIELD,
      PRIORITY_FIELD
    );
    if (String.isBlank(fieldGid)) {
      return SyncResult.failure(
        SyncResult.Outcome.BAD_REQUEST,
        'No Field_Mapping__mdt row of type Field names the Asana custom field for Priority__c, ' +
        'so the priority was not pushed.',
        null
      );
    }
    String optionGid = null;
    if (String.isNotBlank(item.Priority__c)) {
      optionGid = FieldMappingService.externalValueFor(
        SOURCE_SYSTEM,
        FieldMappingService.PRIORITY,
        item.Priority__c
      );
      if (String.isBlank(optionGid)) {
        return SyncResult.failure(
          SyncResult.Outcome.BAD_REQUEST,
          'No Field_Mapping__mdt row of type Priority gives an Asana option for "' +
            item.Priority__c +
            '", so the priority was not pushed.',
          null
        );
      }
    }
    taskUpdate.put(
      'custom_fields',
      new Map<String, Object>{ fieldGid.trim() => optionGid }
    );
    return null;
  }

  /** The section move. Null on success; the failure otherwise. */
  private SyncResult moveToSection(String rawId, String sectionGid) {
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
      return SyncResult.failure(
        SyncResult.Outcome.CALLOUT_FAILED,
        Strings.describe(e),
        0
      );
    }
    if (moved.getStatusCode() < 200 || moved.getStatusCode() >= 300) {
      return toFailure(moved, 'moving the task to section ' + sectionGid);
    }
    return null;
  }

  /**
   * What the task update was doing, for a failure message a person has to act on. When it
   * carried the completion flag the section move had already landed, and saying so is what tells
   * them the task is in the right column but not ticked.
   */
  private static String describeUpdate(
    Map<String, Object> taskUpdate,
    String sectionGid
  ) {
    List<String> parts = new List<String>();
    if (taskUpdate.containsKey('completed')) {
      parts.add(
        'setting completed=' +
          taskUpdate.get('completed') +
          ' after moving the task to section ' +
          sectionGid
      );
    }
    if (taskUpdate.containsKey('name')) {
      parts.add('renaming the task');
    }
    if (taskUpdate.containsKey('due_on')) {
      parts.add('setting due_on');
    }
    if (taskUpdate.containsKey('custom_fields')) {
      parts.add('setting the priority');
    }
    return String.join(parts, ' and ');
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
          'Work item has no usable Asana external id: ' + item.External_Id__c,
          null
        ),
        item,
        item.External_Id__c
      );
    }
    // Deliberately no "already in the target status" short circuit. Jira has one because its
    // first leg is a read that would otherwise be wasted; here both legs are writes, and
    // re-asserting a section and a flag is idempotent and cheap.
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
        'Unspecified is a placeholder for an unmapped status and cannot be a push target.',
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
