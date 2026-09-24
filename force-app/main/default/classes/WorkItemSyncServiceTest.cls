/**
 * Covers orchestration: sync fields, log rows, chunking, and the failure paths that must not
 * take the whole run down with them.
 *
 * Tests that only need the service's behaviour inject a fake adapter rather than mocking HTTP.
 * That is not a shortcut - it is the only way to exercise 200 records, since even mocked callouts
 * count against the 100-per-transaction limit.
 */
@IsTest
private class WorkItemSyncServiceTest {
  /** Records calls and returns a scripted outcome, without touching HTTP. */
  private class FakeAdapter implements IWorkItemAdapter {
    private final SyncResult.Outcome outcome;
    private final Boolean throwInstead;
    private final Boolean emitPoisonLog;
    public Integer calls = 0;

    private FakeAdapter(SyncResult.Outcome outcome) {
      this(outcome, false, false);
    }

    private FakeAdapter(
      SyncResult.Outcome outcome,
      Boolean throwInstead,
      Boolean emitPoisonLog
    ) {
      this.outcome = outcome;
      this.throwInstead = throwInstead;
      this.emitPoisonLog = emitPoisonLog;
    }

    public SyncResult push(Work_Item__c item, Set<SyncField> changed) {
      calls++;
      if (throwInstead) {
        throw new AdapterException('adapter exploded');
      }
      SyncResult result = outcome == SyncResult.Outcome.SUCCESS
        ? SyncResult.pushed(changed, 204)
        : SyncResult.failure(outcome, 'scripted ' + outcome.name(), 500);
      result.workItemId = item.Id;
      result.externalId = item.External_Id__c;
      return result;
    }

    public String normalizeStatus(String remoteStatusName) {
      return 'Unspecified';
    }

    public String normalizeType(String remoteTypeName) {
      return 'Unspecified';
    }

    public List<InboundChange> parseInbound(List<Webhook_Event__c> events) {
      List<InboundChange> changes = new List<InboundChange>();

      for (
        Webhook_Event__c event : events == null
          ? new List<Webhook_Event__c>()
          : events
      ) {
        InboundChange change = new InboundChange();

        change.sourceEventId = event.Id;

        change.failure = 'FakeAdapter has no inbound path.';

        changes.add(change);
      }

      return changes;
    }

    public List<TransitionOption> fetchAvailableTransitions(String externalId) {
      return new List<TransitionOption>();
    }

    public List<Integration_Log__c> drainLogs() {
      return new List<Integration_Log__c>{
        new Integration_Log__c(
          Direction__c = emitPoisonLog ? 'Nonsense' : 'Outbound', // restricted picklist
          HTTP_Method__c = 'POST',
          Status_Code__c = 204,
          Duration_ms__c = 5,
          Is_Success__c = true
        )
      };
    }
  }

  private static List<Work_Item__c> seed(Integer count, String status) {
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    List<Work_Item__c> items = TestDataFactory.createWorkItems(
      count,
      project.Id,
      false
    );
    for (Work_Item__c item : items) {
      item.Status__c = status;
      item.Sync_Status__c = 'Pending';
      // What the trigger records on a real status change. Inserted directly, so it is set here.
      item.Pending_Push_Fields__c = 'STATUS';
    }
    insert items;
    return reread();
  }

  /** Every item, with exactly the fields the queueable hands the service. */
  private static List<Work_Item__c> reread() {
    return Database.query(
      'SELECT ' +
        WorkItemSyncService.ITEM_FIELDS +
        ' FROM Work_Item__c ORDER BY External_Id__c'
    );
  }

  private static Work_Item__c stored() {
    return [
      SELECT
        Sync_Status__c,
        Sync_Error__c,
        Pending_Push_Fields__c,
        Last_Synced__c
      FROM Work_Item__c
      LIMIT 1
    ];
  }

  // ---------- success ----------

  @IsTest
  static void successMarksSyncedAndStampsLastSynced() {
    List<Work_Item__c> items = seed(3, 'In Progress');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    List<SyncResult> results = WorkItemSyncService.pushPending(items);
    Test.stopTest();

    Assert.areEqual(
      3,
      results.size(),
      'Every item should have been attempted.'
    );
    for (Work_Item__c item : [
      SELECT Sync_Status__c, Last_Synced__c
      FROM Work_Item__c
    ]) {
      Assert.areEqual(
        'Synced',
        item.Sync_Status__c,
        'A successful push should mark the item synced.'
      );
      Assert.isNotNull(
        item.Last_Synced__c,
        'Last_Synced__c should be stamped on success.'
      );
    }
  }

  @IsTest
  static void successWritesOneLogRowPerCallout() {
    List<Work_Item__c> items = seed(2, 'In Progress');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(items);
    Test.stopTest();

    List<Integration_Log__c> logs = [
      SELECT HTTP_Method__c, Status_Code__c, Is_Success__c, Work_Item__c
      FROM Integration_Log__c
    ];
    Assert.areEqual(4, logs.size(), 'Two items at two callouts each.');
    for (Integration_Log__c log : logs) {
      Assert.isTrue(log.Is_Success__c, 'All calls succeeded.');
      Assert.isNotNull(
        log.Work_Item__c,
        'Rows should be attributed to their work item.'
      );
    }
  }

  // ---------- failure ----------

  @IsTest
  static void failureMarksFailedAndLeavesLastSyncedAlone() {
    List<Work_Item__c> items = seed(2, 'In Progress');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(items);
    Test.stopTest();

    for (Work_Item__c item : [
      SELECT Sync_Status__c, Last_Synced__c
      FROM Work_Item__c
    ]) {
      Assert.areEqual(
        'Failed',
        item.Sync_Status__c,
        'A 401 should mark the item failed.'
      );
      Assert.isNull(
        item.Last_Synced__c,
        'Last_Synced__c means "agreed", so a failure must not stamp it.'
      );
    }
  }

  @IsTest
  static void failureWritesBothTheCalloutRowAndAnOutcomeRow() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(items);
    Test.stopTest();

    List<Integration_Log__c> calloutRows = [
      SELECT Status_Code__c
      FROM Integration_Log__c
      WHERE HTTP_Method__c != NULL
    ];
    List<Integration_Log__c> outcomeRows = [
      SELECT Error_Message__c, Is_Success__c
      FROM Integration_Log__c
      WHERE HTTP_Method__c = NULL
    ];
    Assert.areEqual(1, calloutRows.size(), 'The 401 callout should be logged.');
    Assert.areEqual(
      401,
      calloutRows[0].Status_Code__c.intValue(),
      'With its real status code.'
    );
    // A null HTTP_Method__c is what distinguishes an outcome row from a callout row.
    Assert.areEqual(
      1,
      outcomeRows.size(),
      'The outcome should be logged separately.'
    );
    Assert.isFalse(
      outcomeRows[0].Is_Success__c,
      'Outcome rows for failures are not successes.'
    );
    Assert.isTrue(
      outcomeRows[0].Error_Message__c.contains('UNAUTHORIZED'),
      'Outcome row should name the outcome: ' + outcomeRows[0].Error_Message__c
    );
  }

  @IsTest
  static void unavailableTransitionIsSurfacedInTheLog() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.NO_MATCHING_TRANSITION)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(items);
    Test.stopTest();

    // The GET succeeded, so without an outcome row this failure would be invisible in the log.
    List<Integration_Log__c> outcomeRows = [
      SELECT Error_Message__c
      FROM Integration_Log__c
      WHERE HTTP_Method__c = NULL
    ];
    Assert.areEqual(
      1,
      outcomeRows.size(),
      'A business outcome still has to be logged.'
    );
    Assert.isTrue(
      outcomeRows[0].Error_Message__c.contains('NO_TRANSITION_AVAILABLE'),
      'Should name the outcome: ' + outcomeRows[0].Error_Message__c
    );
    Assert.areEqual(
      'Failed',
      [SELECT Sync_Status__c FROM Work_Item__c LIMIT 1].Sync_Status__c,
      'Not synced.'
    );
  }

  @IsTest
  static void anItemForAnUnsupportedSystemFailsWithoutStoppingTheRest() {
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    List<Work_Item__c> items = TestDataFactory.createWorkItems(
      2,
      project.Id,
      false
    );
    // trello, not asana: Asana gained an adapter in build 07 step 6. Worse, once real
    // Field_Mapping__mdt rows existed in the org this test started PASSING the Asana item
    // through - FieldMappingService reads live custom metadata when nothing is injected, so
    // org data quietly changed what this test measured.
    items[0].External_Id__c = 'trello:998877'; // genuinely no adapter registered
    for (Work_Item__c item : items) {
      item.Status__c = 'In Progress';
      item.Sync_Status__c = 'Pending';
      item.Pending_Push_Fields__c = 'STATUS';
    }
    insert items;
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    List<SyncResult> results = WorkItemSyncService.pushPending(reread());
    Test.stopTest();

    Assert.areEqual(2, results.size(), 'Both items should produce a result.');
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
      'The Jira item should still have synced.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Failed'],
      'The unsupported item should have failed on its own.'
    );
  }

  @IsTest
  static void anUnexpectedAdapterExceptionIsContainedPerItem() {
    List<Work_Item__c> items = seed(3, 'In Progress');
    WorkItemAdapterFactory.injected = new FakeAdapter(
      SyncResult.Outcome.SUCCESS,
      true,
      false
    );

    Test.startTest();
    List<SyncResult> results = WorkItemSyncService.pushPending(items);
    Test.stopTest();

    Assert.areEqual(
      3,
      results.size(),
      'One bad item must not strand the others.'
    );
    for (SyncResult result : results) {
      Assert.areEqual(
        SyncResult.Outcome.CALLOUT_FAILED,
        result.outcome,
        'Should be caught and classified.'
      );
    }
    Assert.areEqual(
      3,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Failed'],
      'All marked failed.'
    );
  }

  @IsTest
  static void aLoggingFailureDoesNotBreakTheSync() {
    List<Work_Item__c> items = seed(2, 'In Progress');
    // Direction__c is a restricted picklist, so this row cannot be inserted.
    WorkItemAdapterFactory.injected = new FakeAdapter(
      SyncResult.Outcome.SUCCESS,
      false,
      true
    );

    Test.startTest();
    List<SyncResult> results = WorkItemSyncService.pushPending(items);
    Test.stopTest();

    Assert.areEqual(2, results.size(), 'The sync itself should be unaffected.');
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
      'Items must still be marked synced when their log rows cannot be written.'
    );
  }

  // ---------- limits and chunking ----------

  @IsTest
  static void stopsEarlyWhenTheCalloutTimeBudgetIsGone() {
    List<Work_Item__c> items = seed(3, 'In Progress');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    WorkItemSyncService.calloutTimeBudgetMs = 0; // pretend the budget is already spent

    Test.startTest();
    List<SyncResult> results = WorkItemSyncService.pushPending(items);
    Test.stopTest();

    // Being killed mid-chunk loses the buffered logs, so stopping short is the safe failure.
    Assert.areEqual(
      0,
      results.size(),
      'Nothing should be attempted with no budget left.'
    );
    Assert.areEqual(
      3,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Pending'],
      'Unattempted items keep their pending status for the next chunk.'
    );
  }

  @IsTest
  static void queueableProcessesOneChunkAndLeavesTheRest() {
    List<Work_Item__c> items = seed(200, 'In Progress');
    List<Id> ids = new List<Id>(new Map<Id, Work_Item__c>(items).keySet());
    // No HTTP: 200 items would be 400 callouts, and mocked callouts count against the limit.
    WorkItemAdapterFactory.injected = new FakeAdapter(
      SyncResult.Outcome.SUCCESS
    );

    Test.startTest();
    System.enqueueJob(new WorkItemSyncQueueable(ids));
    Test.stopTest();

    Assert.areEqual(
      WorkItemSyncService.DEFAULT_CHUNK_SIZE,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
      'Exactly one chunk should have been processed.'
    );
    Assert.areEqual(
      200 - WorkItemSyncService.DEFAULT_CHUNK_SIZE,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Pending'],
      'The remainder waits for the next link in the chain, which test context suppresses.'
    );
  }

  @IsTest
  static void bulkRunUsesConstantDml() {
    List<Work_Item__c> items = seed(200, 'In Progress');
    WorkItemAdapterFactory.injected = new FakeAdapter(
      SyncResult.Outcome.SUCCESS
    );

    Test.startTest();
    Integer dmlBefore = Limits.getDmlStatements();
    WorkItemSyncService.pushPending(items);
    Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
    Test.stopTest();

    // One update for the items, one insert for the logs, regardless of volume.
    Assert.areEqual(
      2,
      dmlUsed,
      'DML must not scale with the number of records.'
    );
    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
      'All synced.'
    );
  }

  @IsTest
  static void emptyAndNullInputAreNoOps() {
    Test.startTest();
    Assert.areEqual(
      0,
      WorkItemSyncService.pushPending(null).size(),
      'Null input should be a no-op.'
    );
    Assert.areEqual(
      0,
      WorkItemSyncService.pushPending(new List<Work_Item__c>()).size(),
      'Empty likewise.'
    );
    Assert.isNull(
      WorkItemSyncService.enqueue(new List<Id>()),
      'Nothing to enqueue means no job.'
    );
    Assert.isNull(WorkItemSyncService.enqueue(null), 'Null likewise.');
    Test.stopTest();
  }

  @IsTest
  static void enqueueReturnsAJobId() {
    List<Work_Item__c> items = seed(2, 'In Progress');
    WorkItemAdapterFactory.injected = new FakeAdapter(
      SyncResult.Outcome.SUCCESS
    );

    Test.startTest();
    Id jobId = WorkItemSyncService.enqueue(
      new List<Id>(new Map<Id, Work_Item__c>(items).keySet())
    );
    Test.stopTest();

    Assert.isNotNull(jobId, 'Callers need the job id to track the run.');
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
      'Job should have run.'
    );
  }

  // ---------- factory ----------

  @IsTest
  static void factoryRoutesOnTheIdNamespace() {
    Test.startTest();
    Assert.isTrue(
      WorkItemAdapterFactory.forWorkItem(
        new Work_Item__c(External_Id__c = 'jira:10023')
      ) instanceof JiraAdapter,
      'A jira-namespaced id should route to the Jira adapter.'
    );
    // Asana routes as of build 07 step 6. This assertion named it as the unregistered system
    // until then, and updating it was the deliberate act of registering a second adapter.
    Assert.isTrue(
      WorkItemAdapterFactory.forWorkItem(
        new Work_Item__c(External_Id__c = 'asana:1210000000000001')
      ) instanceof AsanaAdapter,
      'An asana-namespaced id should route to the Asana adapter.'
    );
    try {
      WorkItemAdapterFactory.forSystem('trello');
      Assert.fail('An unregistered system should be refused.');
    } catch (WorkItemAdapterFactory.UnsupportedSystemException e) {
      Assert.isTrue(
        e.getMessage().contains('trello'),
        'Message should name the system.'
      );
    }
    try {
      WorkItemAdapterFactory.forWorkItem(null);
      Assert.fail('A null work item should be refused.');
    } catch (WorkItemAdapterFactory.UnsupportedSystemException e) {
      Assert.isNotNull(e.getMessage(), 'Exception should explain itself.');
    }
    Test.stopTest();
  }

  // ---------- what the write-back records (build 08) ----------

  @IsTest
  static void successClearsThePendingFieldsAndAnyOldError() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    Work_Item__c failedBefore = new Work_Item__c(
      Id = items[0].Id,
      Sync_Error__c = 'An old failure.'
    );
    update failedBefore;
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(reread());
    Test.stopTest();

    Work_Item__c after = stored();
    Assert.areEqual('Synced', after.Sync_Status__c);
    Assert.isNull(after.Pending_Push_Fields__c, 'Nothing left to push.');
    Assert.isNull(
      after.Sync_Error__c,
      'A reason for a failure that has since been fixed would be a false one.'
    );
    Assert.isNotNull(after.Last_Synced__c);
  }

  @IsTest
  static void aFailureRecordsItsReasonAndKeepsTheFieldPending() {
    seed(1, 'In Progress');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(reread());
    Test.stopTest();

    Work_Item__c after = stored();
    Assert.areEqual('Failed', after.Sync_Status__c);
    Assert.isTrue(
      after.Sync_Error__c.contains('401'),
      'The card can say why: ' + after.Sync_Error__c
    );
    Assert.areEqual(
      'STATUS',
      after.Pending_Push_Fields__c,
      'Still waiting, so the record cannot read Synced while the change never landed.'
    );
    Assert.isNull(after.Last_Synced__c);
  }

  @IsTest
  static void onlyWhatTheSourceConfirmedIsCleared() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    update new Work_Item__c(
      Id = items[0].Id,
      Pending_Push_Fields__c = 'STATUS;TITLE'
    );
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.NO_MATCHING_TRANSITION)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(reread());
    Test.stopTest();

    Work_Item__c after = stored();
    Assert.areEqual(
      'STATUS',
      after.Pending_Push_Fields__c,
      'The title landed and is cleared; the refused status is not.'
    );
    Assert.areEqual('Failed', after.Sync_Status__c);
    Assert.isTrue(
      after.Sync_Error__c.contains('Available'),
      after.Sync_Error__c
    );
  }

  @IsTest
  static void anEditMadeDuringThePushIsKeptAndLeftPending() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    update new Work_Item__c(Id = items[0].Id, Pending_Push_Fields__c = 'TITLE');
    // What the job reads when it starts...
    List<Work_Item__c> atStart = reread();
    // ...and what the row says by the time it writes back: the user changed the due date in
    // between, which staged it and queued a job of its own.
    update new Work_Item__c(
      Id = items[0].Id,
      Pending_Push_Fields__c = 'TITLE;DUE_DATE'
    );
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(atStart);
    Test.stopTest();

    Work_Item__c after = stored();
    Assert.areEqual(
      'DUE_DATE',
      after.Pending_Push_Fields__c,
      'Only the title was pushed, so only the title is cleared. Writing back the set the job ' +
      'started with would erase the due date, and its own job would then push nothing.'
    );
    Assert.areEqual(
      'Pending',
      after.Sync_Status__c,
      'Not Synced: the due date has not reached Jira yet.'
    );
    Assert.isNull(after.Last_Synced__c, 'They do not agree yet.');
  }

  @IsTest
  static void aRecordWithNothingPendingIsNeitherPushedNorWritten() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    update new Work_Item__c(
      Id = items[0].Id,
      Pending_Push_Fields__c = null,
      Sync_Status__c = 'Failed'
    );
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    Integer before = Limits.getCallouts();
    List<SyncResult> results = WorkItemSyncService.pushPending(reread());
    Integer used = Limits.getCallouts() - before;
    Test.stopTest();

    Assert.areEqual(0, used, 'Nothing waiting, nothing sent.');
    Assert.areEqual(
      SyncResult.Outcome.NOTHING_TO_PUSH,
      results[0].outcome,
      'Still reported, so the queueable counts it as handled rather than chaining for ever.'
    );
    Assert.areEqual(
      'Failed',
      stored().Sync_Status__c,
      'And nothing written: an earlier job\'s Failed is not overwritten with a Synced.'
    );
  }

  @IsTest
  static void aTitleOnlyPushCostsOneCallout() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    update new Work_Item__c(Id = items[0].Id, Pending_Push_Fields__c = 'TITLE');
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    // Both readings inside the window: stopTest restores the outer context's limits, so a
    // reading taken after it would count the wrong transaction.
    Integer before = Limits.getCallouts();
    WorkItemSyncService.pushPending(reread());
    Integer used = Limits.getCallouts() - before;
    Test.stopTest();

    Assert.areEqual(1, used, 'One PUT; a title needs no transition.');
    Assert.areEqual('Synced', stored().Sync_Status__c);
  }

  @IsTest
  static void anUnspecifiedStatusStaysPendingEvenWhenItsTitleLands() {
    List<Work_Item__c> items = seed(1, 'In Progress');
    update new Work_Item__c(
      Id = items[0].Id,
      Status__c = 'Unspecified',
      Pending_Push_Fields__c = 'TITLE'
    );
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    WorkItemSyncService.pushPending(reread());
    Test.stopTest();

    Work_Item__c after = stored();
    Assert.isNull(after.Pending_Push_Fields__c, 'The title landed.');
    Assert.areEqual(
      'Pending',
      after.Sync_Status__c,
      'Synced is illegal beside Unspecified, and the status is unreconciled anyway.'
    );
  }
}
