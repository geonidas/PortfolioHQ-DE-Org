/**
 * The Asana outbound path: two writes that must both happen, and who is allowed to trigger them.
 *
 * Kept apart from AsanaAdapterTest because the inbound tests must not commit any DML - the
 * adapter calls out from parseInbound, and DML before a callout throws. These tests need real
 * records, and push callouts happen after the DML rather than before it, so the two halves
 * cannot share a class without one of them lying about the ordering it depends on.
 */
@IsTest
private class AsanaOutboundTest {
  private static final String TASK_GID = '1210000000000042';

  private static void mapStatuses() {
    FieldMappingService.reset();
    FieldMappingService.injected = AsanaPayloadFactory.statusMappings();
  }

  private static Work_Item__c asanaItem(String status, Boolean isPublic) {
    Project__c project = TestDataFactory.createProjects(1, false)[0];
    project.External_System__c = ExternalSystem.ASANA;
    project.External_Project_Key__c = AsanaPayloadFactory.PROJECT_GID;
    insert project;

    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.External_Id__c = 'asana:' + TASK_GID;
    item.External_Key__c = null;
    item.External_System__c = ExternalSystem.ASANA;
    item.Status__c = status;
    item.Sync_Status__c = SyncStatus.PENDING;
    item.Is_Public__c = isPublic;
    insert item;
    return item;
  }

  /** Every write Asana received, in order. */
  private static AsanaWriteMock push(Work_Item__c item, String targetStatus) {
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    AsanaAdapter adapter = new AsanaAdapter();
    lastResult = pushStatus(adapter, item, targetStatus);
    lastLogs = adapter.drainLogs();
    return mock;
  }

  /** A status change as the service now asks for one: the record's own status, as a field. */
  private static SyncResult pushStatus(
    AsanaAdapter adapter,
    Work_Item__c item,
    String targetStatus
  ) {
    item.Status__c = targetStatus;
    return adapter.push(item, new Set<SyncField>{ SyncField.STATUS });
  }

  private static SyncResult lastResult;
  private static List<Integration_Log__c> lastLogs;

  // ---------- the two writes ----------

  @IsTest
  static void movingToDoneWritesBothTheSectionAndTheFlag() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);

    Test.startTest();
    AsanaWriteMock mock = push(item, WorkItemStatus.DONE);
    Test.stopTest();

    Assert.isTrue(lastResult.isSuccess(), 'Failure: ' + lastResult.message);
    Assert.areEqual(
      2,
      mock.callCount(),
      'Two writes, not one. Asana models the column and the checkbox independently, and ' +
      'writing only one authors the contradiction step 6 exists to absorb.'
    );
    Assert.isTrue(
      mock.captured[0]
        .endpoint.contains(
          '/sections/' + AsanaPayloadFactory.SECTION_COMPLETED + '/addTask'
        ),
      'First the section move, to the gid the mapping table names: ' +
      mock.captured[0].endpoint
    );
    Assert.isTrue(
      mock.captured[0].body.contains(TASK_GID),
      'Carrying the raw task gid, not the namespaced external id: ' +
      mock.captured[0].body
    );
    Assert.isTrue(
      mock.captured[1].endpoint.endsWith('/tasks/' + TASK_GID),
      'Then the completion flag on the task itself: ' +
      mock.captured[1].endpoint
    );
    Assert.areEqual('PUT', mock.captured[1].method);
    Assert.isTrue(
      mock.captured[1].body.contains('"completed":true'),
      'Set, because the target is Done: ' + mock.captured[1].body
    );
  }

  @IsTest
  static void movingOutOfDoneWritesBothInReverse() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.DONE, false);

    Test.startTest();
    AsanaWriteMock mock = push(item, WorkItemStatus.IN_PROGRESS);
    Test.stopTest();

    Assert.isTrue(lastResult.isSuccess(), 'Failure: ' + lastResult.message);
    Assert.areEqual(2, mock.callCount(), 'Still two writes.');
    Assert.isTrue(
      mock.captured[0]
        .endpoint.contains(
          '/sections/' + AsanaPayloadFactory.SECTION_IN_PROGRESS + '/addTask'
        ),
      'Moved to the target section: ' + mock.captured[0].endpoint
    );
    Assert.isTrue(
      mock.captured[1].body.contains('"completed":false'),
      'And un-ticked, or the task would stay struck through in a column that says otherwise: ' +
      mock.captured[1].body
    );
  }

  @IsTest
  static void anUnmappedTargetStatusLogsAndCallsOutToNothing() {
    // In Review has no Asana section, and that asymmetry is correct rather than a gap to paper
    // over - Asana has no In Review column and inventing one would be a lie about the board.
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);

    Test.startTest();
    Integer before = Limits.getCallouts();
    AsanaWriteMock mock = push(item, WorkItemStatus.IN_REVIEW);
    Integer after = Limits.getCallouts();
    Test.stopTest();

    Assert.isFalse(lastResult.isSuccess(), 'There is nowhere to move it to.');
    Assert.areEqual(
      before,
      after,
      'And nothing was sent. The mapping is resolved before any callout, so a configuration ' +
      'gap costs no HTTP at all.'
    );
    Assert.areEqual(0, mock.callCount());
    Assert.areEqual(
      1,
      lastLogs.size(),
      'One row says which mapping is missing.'
    );
    Assert.isTrue(
      lastLogs[0].Error_Message__c.contains('In Review'),
      'Naming the status: ' + lastLogs[0].Error_Message__c
    );
  }

  @IsTest
  static void aFailedSectionMoveNeverWritesTheFlag() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(500);
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = pushStatus(
      new AsanaAdapter(),
      item,
      WorkItemStatus.DONE
    );
    Test.stopTest();

    Assert.isFalse(result.isSuccess());
    Assert.areEqual(
      1,
      mock.callCount(),
      'The second write is not attempted. Ticking completed on a task still sitting in ' +
      'In Progress would author the contradiction rather than avoid it.'
    );
  }

  @IsTest
  static void anItemWithNoAsanaIdIsRefusedWithoutCallingOut() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.External_Id__c = 'jira:10039';

    Test.startTest();
    Integer before = Limits.getCallouts();
    AsanaWriteMock mock = push(item, WorkItemStatus.DONE);
    Integer after = Limits.getCallouts();
    Test.stopTest();

    Assert.isFalse(
      result(),
      'An id for another system is not this adapter\'s to push.'
    );
    Assert.areEqual(before, after, 'And nothing was sent.');
    Assert.areEqual(0, mock.callCount());
  }

  @IsTest
  static void unspecifiedIsNeverPushed() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);

    Test.startTest();
    AsanaWriteMock mock = push(item, WorkItemStatus.UNSPECIFIED);
    Test.stopTest();

    Assert.isFalse(
      result(),
      'Unspecified means "no mapping", so there is nothing to ask Asana for.'
    );
    Assert.areEqual(0, mock.callCount());
  }

  @IsTest
  static void aFailedCompletionWriteIsReportedAsSuchNotAsSuccess() {
    // The half-applied case. The section move landed, so the board looks right; the flag did
    // not, so Asana still thinks the task is unfinished. Reporting success here would leave a
    // record marked Synced that disagrees with the remote system for ever.
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(new List<Integer>{ 200, 500 });
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult outcome = pushStatus(
      new AsanaAdapter(),
      item,
      WorkItemStatus.DONE
    );
    Test.stopTest();

    Assert.isFalse(outcome.isSuccess(), 'Half applied is not applied.');
    Assert.areEqual(2, mock.callCount(), 'Both writes were attempted.');
    Assert.isTrue(
      outcome.message.contains('completed=true'),
      'And the message says which half failed: ' + outcome.message
    );
  }

  @IsTest
  static void remoteRefusalsAreClassified() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);

    Test.startTest();
    Test.setMock(HttpCalloutMock.class, new AsanaWriteMock(401));
    SyncResult unauthorized = pushStatus(
      new AsanaAdapter(),
      item,
      WorkItemStatus.DONE
    );
    Test.setMock(HttpCalloutMock.class, new AsanaWriteMock(429));
    SyncResult throttled = pushStatus(
      new AsanaAdapter(),
      item,
      WorkItemStatus.DONE
    );
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.UNAUTHORIZED,
      unauthorized.outcome,
      'A credential problem is not a transient one, and should not be retried into working.'
    );
    Assert.areEqual(
      SyncResult.Outcome.RATE_LIMITED,
      throttled.outcome,
      'And a 429 is, which is a different decision for whoever reads the log.'
    );
  }

  @IsTest
  static void badRequestsAreRefusedBeforeAnyCallout() {
    mapStatuses();

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    AsanaAdapter adapter = new AsanaAdapter();
    SyncResult noItem = adapter.push(
      null,
      new Set<SyncField>{ SyncField.STATUS }
    );
    SyncResult noStatus = adapter.push(
      new Work_Item__c(External_Id__c = 'asana:' + TASK_GID, Status__c = ''),
      new Set<SyncField>{ SyncField.STATUS }
    );
    Test.stopTest();

    Assert.areEqual(SyncResult.Outcome.BAD_REQUEST, noItem.outcome);
    Assert.areEqual(SyncResult.Outcome.BAD_REQUEST, noStatus.outcome);
    Assert.areEqual(
      0,
      mock.callCount(),
      'None of these reach the wire. The adapter contracts not to throw, so they come back ' +
      'as results instead.'
    );
  }

  @IsTest
  static void reachableStatusesComeFromTheMappingTableNotACallout() {
    // Asana has no workflow to ask: every mapped section is reachable from every other one,
    // because moving a task between columns is never refused. So the answer does not depend on
    // the task, and costs nothing.
    mapStatuses();

    Test.startTest();
    Integer before = Limits.getCallouts();
    List<TransitionOption> options = new AsanaAdapter()
      .fetchAvailableTransitions('asana:' + TASK_GID);
    Integer after = Limits.getCallouts();
    Test.stopTest();

    Assert.areEqual(before, after, 'No callout: there is nothing to ask.');
    Set<String> statuses = new Set<String>();
    for (TransitionOption option : options) {
      statuses.add(option.targetStatus);
    }
    Assert.areEqual(
      new Set<String>{
        WorkItemStatus.TO_DO,
        WorkItemStatus.IN_PROGRESS,
        WorkItemStatus.DONE
      },
      statuses,
      'The three the learning project maps. In Review is absent because Asana has no such ' +
      'column, and that asymmetry is correct rather than a gap to invent a section for.'
    );
  }

  @IsTest
  static void anIdForAnotherSystemIsRefusedOutright() {
    mapStatuses();

    Test.startTest();
    Boolean threw = false;
    try {
      new AsanaAdapter().fetchAvailableTransitions('jira:10039');
    } catch (AdapterException e) {
      threw = true;
    }
    Test.stopTest();

    Assert.isTrue(
      threw,
      'Unlike push, this one throws: an empty list would mean "nowhere to go", which ' +
      'is a different and misleading answer.'
    );
  }

  // ---------- who triggers a push ----------

  @IsTest
  static void aPrivateItemsStatusChangeEnqueuesOneJob() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.TO_DO, false);

    Test.startTest();
    item.Status__c = WorkItemStatus.IN_PROGRESS;
    update item;
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      1,
      queued,
      'A private Asana record behaves exactly as a private Jira one does - the queueable does ' +
      'not know which system it is pushing to.'
    );
  }

  @IsTest
  static void aPublicItemsStatusChangeEnqueuesOneJobToo() {
    // Build 07 step 8 made sync inbound-only for anything flagged public; step 9 took that
    // back out. Is_Public__c is a read gate for the guest board and nothing else, so an item
    // being visible to a visitor is no reason for the internal board to stop being able to
    // move it. Asana's half of the same assertion in WorkItemTriggerHandlerTest.
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.TO_DO, true);

    Test.startTest();
    item.Status__c = WorkItemStatus.IN_PROGRESS;
    update item;
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      1,
      queued,
      'Public and private behave identically. The rule lives in WorkItemTriggerHandler and is ' +
      'vendor-neutral, so a 0 here means every public Jira item has gone read-only as well.'
    );
  }

  @IsTest
  static void anItemWithNoExternalIdEnqueuesNothing() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.TO_DO, false);
    item.External_Id__c = null;
    update item;

    Test.startTest();
    item.Status__c = WorkItemStatus.IN_PROGRESS;
    update item;
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      0,
      queued,
      'Nothing remote to push to. Existing rule, still true for a second system.'
    );
  }

  @IsTest
  static void anInboundAppliedChangeEnqueuesNothing() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.TO_DO, false);

    Test.startTest();
    SyncContext.suppressOutbound();
    try {
      item.Status__c = WorkItemStatus.IN_PROGRESS;
      update item;
    } finally {
      SyncContext.resumeOutbound();
    }
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      0,
      queued,
      'Applying a webhook must not bounce straight back out to the system it came from.'
    );
  }

  @IsTest
  static void twoHundredStatusChangesCostOneJob() {
    mapStatuses();
    Project__c project = TestDataFactory.createProjects(1, false)[0];
    project.External_System__c = ExternalSystem.ASANA;
    project.External_Project_Key__c = AsanaPayloadFactory.PROJECT_GID;
    insert project;

    List<Work_Item__c> items = TestDataFactory.createWorkItems(
      200,
      project.Id,
      false
    );
    for (Integer i = 0; i < items.size(); i++) {
      // Built as a string: a gid is longer than Apex's Integer range, and the literal
      // arithmetic would not compile.
      items[i].External_Id__c = 'asana:121000000' + String.valueOf(1000 + i);
      items[i].External_Key__c = null;
      items[i].External_System__c = ExternalSystem.ASANA;
      items[i].Status__c = WorkItemStatus.TO_DO;
      items[i].Sync_Status__c = SyncStatus.PENDING;
    }
    insert items;

    Test.startTest();
    for (Work_Item__c item : items) {
      item.Status__c = WorkItemStatus.IN_PROGRESS;
    }
    update items;
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      1,
      queued,
      'One job for the whole update, chunked inside. A job per record would blow the limit at ' +
      'fifty and the trigger would fail the DML.'
    );
  }

  private static Boolean result() {
    return lastResult != null && lastResult.isSuccess();
  }

  // ---------- pushing fields (build 08) ----------

  private static Map<String, Object> dataOf(
    AsanaWriteMock.CapturedRequest call
  ) {
    return (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        call.body
      ))
      .get('data');
  }

  @IsTest
  static void aTitleAndDueDateAreOneTaskUpdateCarryingOnlyThose() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.Title__c = 'Deep Work by Cal Newport';
    item.Due_Date__c = Date.newInstance(2026, 10, 3);

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = new AsanaAdapter()
      .push(item, new Set<SyncField>{ SyncField.TITLE, SyncField.DUE_DATE });
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Assert.areEqual(1, mock.callCount(), 'No section move without a status.');
    Assert.areEqual('PUT', mock.captured[0].method);
    Assert.isTrue(mock.captured[0].endpoint.endsWith('/tasks/' + TASK_GID));
    Map<String, Object> data = dataOf(mock.captured[0]);
    Assert.areEqual(
      new Set<String>{ 'name', 'due_on' },
      data.keySet(),
      'Only what changed - and never start_on, never completed.'
    );
    Assert.areEqual('Deep Work by Cal Newport', data.get('name'));
    Assert.areEqual('2026-10-03', data.get('due_on'));
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE, SyncField.DUE_DATE },
      result.confirmedFields
    );
  }

  @IsTest
  static void aStatusChangeAndAnEditShareTheSecondWrite() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.Status__c = WorkItemStatus.DONE;
    item.Title__c = 'Finished it';

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = new AsanaAdapter()
      .push(item, new Set<SyncField>{ SyncField.STATUS, SyncField.TITLE });
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Assert.areEqual(
      2,
      mock.callCount(),
      'Still two writes: the edit rides on the completion flag\'s update.'
    );
    Map<String, Object> data = dataOf(mock.captured[1]);
    Assert.areEqual(true, data.get('completed'));
    Assert.areEqual('Finished it', data.get('name'));
    Assert.areEqual(
      new Set<SyncField>{ SyncField.STATUS, SyncField.TITLE },
      result.confirmedFields
    );
  }

  @IsTest
  static void aStartDateIsRefusedWithoutACalloutWhileTheRestStillGoes() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.Start_Date__c = Date.newInstance(2026, 9, 1);
    item.Title__c = 'Renamed';

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = new AsanaAdapter()
      .push(item, new Set<SyncField>{ SyncField.START_DATE, SyncField.TITLE });
    Test.stopTest();

    Assert.areEqual(SyncResult.Outcome.BAD_REQUEST, result.outcome);
    Assert.areEqual(1, mock.callCount());
    Assert.isFalse(
      mock.captured[0].body.contains('start_on'),
      'start_on never leaves Salesforce: ' + mock.captured[0].body
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      result.confirmedFields,
      'The title still landed.'
    );
  }

  @IsTest
  static void clearingAStartDateCountsAsDoneWithNothingSent() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.Start_Date__c = null;

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = new AsanaAdapter()
      .push(item, new Set<SyncField>{ SyncField.START_DATE });
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Assert.areEqual(
      0,
      mock.callCount(),
      'Salesforce never sent Asana a start date, so there is none to clear.'
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.START_DATE },
      result.confirmedFields
    );
  }

  @IsTest
  static void aFailedSectionMoveStillSendsTheEditButNotTheFlag() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.Status__c = WorkItemStatus.DONE;
    item.Title__c = 'Renamed';

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(new List<Integer>{ 500, 200 });
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = new AsanaAdapter()
      .push(item, new Set<SyncField>{ SyncField.STATUS, SyncField.TITLE });
    Test.stopTest();

    Assert.isFalse(result.isSuccess());
    Assert.areEqual(2, mock.callCount());
    Map<String, Object> data = dataOf(mock.captured[1]);
    Assert.isFalse(
      data.containsKey('completed'),
      'No flag after a failed move - that would author the contradiction.'
    );
    Assert.areEqual('Renamed', data.get('name'));
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      result.confirmedFields
    );
  }

  // ---------- priority (build 09) ----------

  private static void mapStatusesAndPriorities() {
    mapStatuses();
    FieldMappingService.injected.addAll(AsanaPayloadFactory.priorityMappings());
  }

  @IsTest
  static void aPriorityOnlySaveSendsOnlyThePriorityAsAnOptionGid() {
    mapStatusesAndPriorities();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    Map<String, String> gidByValue = new Map<String, String>{
      'High' => AsanaPayloadFactory.PRIORITY_HIGH,
      'Medium' => AsanaPayloadFactory.PRIORITY_MEDIUM,
      'Low' => AsanaPayloadFactory.PRIORITY_LOW,
      null => null
    };
    List<String> order = new List<String>{ 'High', 'Medium', 'Low', null };

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    List<SyncResult> results = new List<SyncResult>();
    for (String value : order) {
      item.Priority__c = value;
      results.add(
        new AsanaAdapter().push(item, new Set<SyncField>{ SyncField.PRIORITY })
      );
    }
    Test.stopTest();

    Assert.areEqual(4, mock.callCount(), 'One task update per push.');
    for (Integer i = 0; i < order.size(); i++) {
      Assert.isTrue(results[i].isSuccess(), 'Failure: ' + results[i].message);
      Map<String, Object> data = dataOf(mock.captured[i]);
      Assert.areEqual(
        new Set<String>{ 'custom_fields' },
        data.keySet(),
        'Only the priority - never completed, never the name.'
      );
      Map<String, Object> customFields = (Map<String, Object>) data.get(
        'custom_fields'
      );
      Assert.areEqual(
        new Set<String>{ AsanaPayloadFactory.PRIORITY_FIELD_GID },
        customFields.keySet(),
        'Keyed on the field gid.'
      );
      Assert.areEqual(
        gidByValue.get(order[i]),
        customFields.get(AsanaPayloadFactory.PRIORITY_FIELD_GID),
        'The option gid for ' +
          order[i] +
          '; null empties the field, Asana\'s none.'
      );
      Assert.areEqual(
        new Set<SyncField>{ SyncField.PRIORITY },
        results[i].confirmedFields
      );
    }
  }

  @IsTest
  static void aTitleAndPriorityAreOneTaskUpdate() {
    mapStatusesAndPriorities();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.Title__c = 'Deep Work by Cal Newport';
    item.Priority__c = 'Low';

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = new AsanaAdapter()
      .push(item, new Set<SyncField>{ SyncField.TITLE, SyncField.PRIORITY });
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Assert.areEqual(1, mock.callCount(), 'One write.');
    Assert.areEqual(
      new Set<String>{ 'name', 'custom_fields' },
      dataOf(mock.captured[0]).keySet()
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE, SyncField.PRIORITY },
      result.confirmedFields
    );
  }

  @IsTest
  static void withNoPriorityFieldRowThePriorityIsRefusedWhileTheRestStillGoes() {
    mapStatuses();
    Work_Item__c item = asanaItem(WorkItemStatus.IN_PROGRESS, false);
    item.Title__c = 'Deep Work by Cal Newport';
    item.Priority__c = 'High';

    Test.startTest();
    AsanaWriteMock mock = new AsanaWriteMock(200);
    Test.setMock(HttpCalloutMock.class, mock);
    SyncResult result = new AsanaAdapter()
      .push(item, new Set<SyncField>{ SyncField.TITLE, SyncField.PRIORITY });
    Test.stopTest();

    Assert.areEqual(SyncResult.Outcome.BAD_REQUEST, result.outcome);
    Assert.isTrue(
      result.message.contains('type Field'),
      'Says what to add: ' + result.message
    );
    Assert.areEqual(
      new Set<String>{ 'name' },
      dataOf(mock.captured[0]).keySet(),
      'The title still goes, without a custom_fields key.'
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      result.confirmedFields
    );
  }
}
