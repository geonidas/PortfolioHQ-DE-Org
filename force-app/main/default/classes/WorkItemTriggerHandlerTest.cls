/**
 * The outbound trigger's guards, tested on their own terms.
 *
 * WorkItemInboundProcessorTest already proves the interaction with inbound suppression and the
 * explicit-Sync_Status__c rule, because those are where the loop would close. This class covers
 * what was only ever asserted indirectly: which changes never stage, which never enqueue, and
 * that volume costs one job rather than one per record.
 */
@IsTest
private class WorkItemTriggerHandlerTest {
  private static Work_Item__c seed(
    String status,
    String syncStatus,
    Boolean withExternalId
  ) {
    // Any push these tests queue runs at stopTest; without a mock its callout would fail the
    // job. Tests that care what was sent set their own.
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.Status__c = status;
    item.Sync_Status__c = syncStatus;
    if (!withExternalId) {
      item.External_Id__c = null;
    }
    insert item;
    return item;
  }

  private static Integer jobsQueuedBy(Work_Item__c change) {
    Integer before = Limits.getQueueableJobs();
    update change;
    return Limits.getQueueableJobs() - before;
  }

  private static String syncStatusOf(Id workItemId) {
    return [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :workItemId]
    .Sync_Status__c;
  }

  private static Work_Item__c stagedOf(Id workItemId) {
    return [
      SELECT Sync_Status__c, Pending_Push_Fields__c, Sync_Error__c
      FROM Work_Item__c
      WHERE Id = :workItemId
    ];
  }

  @IsTest
  static void aRealStatusChangeStagesPendingAndQueuesOnePush() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = seed('To Do', 'Synced', true);

    Test.startTest();
    Integer queued = jobsQueuedBy(
      new Work_Item__c(Id = item.Id, Status__c = 'In Progress')
    );
    // Read before stopTest runs the job, which will move the record on to Synced again.
    String staged = syncStatusOf(item.Id);
    Test.stopTest();

    Assert.areEqual(
      'Pending',
      staged,
      'before update must drop the stale Synced belief, or the adapter skips its callout.'
    );
    Assert.areEqual(1, queued, 'One push, queued by the trigger.');
  }

  @IsTest
  static void unspecifiedNeverStagesOrPushes() {
    // Failed rather than Synced, because Synced alongside Unspecified is illegal and the
    // validation rule would fail the update before the trigger's own guard was exercised.
    Work_Item__c item = seed('To Do', 'Failed', true);

    Test.startTest();
    Integer queued = jobsQueuedBy(
      new Work_Item__c(Id = item.Id, Status__c = 'Unspecified')
    );
    Test.stopTest();

    Assert.areEqual(0, queued, 'There is nothing to ask Jira for.');
    Assert.areEqual(
      'Failed',
      syncStatusOf(item.Id),
      'And nothing was staged: Sync_Status__c is untouched.'
    );
  }

  @IsTest
  static void aRecordTheRemoteSystemDoesNotKnowNeverStagesOrPushes() {
    Work_Item__c item = seed('To Do', 'Failed', false);

    Test.startTest();
    Integer queued = jobsQueuedBy(
      new Work_Item__c(Id = item.Id, Status__c = 'Done')
    );
    Test.stopTest();

    Assert.areEqual(0, queued, 'No External_Id__c, no remote record to move.');
    Assert.areEqual('Failed', syncStatusOf(item.Id), 'Nothing staged.');
  }

  @IsTest
  static void aSuppressedContextStagesNothingAndPushesNothing() {
    Work_Item__c item = seed('To Do', 'Failed', true);

    Test.startTest();
    Integer queued;
    SyncContext.suppressOutbound();
    try {
      queued = jobsQueuedBy(
        new Work_Item__c(Id = item.Id, Status__c = 'In Progress')
      );
    } finally {
      SyncContext.resumeOutbound();
    }
    Test.stopTest();

    Assert.areEqual(
      0,
      queued,
      'Inbound is applying this; it must not bounce back out.'
    );
    Assert.areEqual(
      'Failed',
      syncStatusOf(item.Id),
      'Staging stands down too: the Sync_Status__c inbound sets is authoritative.'
    );
  }

  @IsTest
  static void aChangeToNoPushableFieldPushesNothing() {
    // Title was in this list until build 08, when it became pushable. What is left here is
    // what the sources never receive.
    Work_Item__c item = seed('To Do', 'Failed', true);

    Test.startTest();
    Integer queued = jobsQueuedBy(
      new Work_Item__c(Id = item.Id, Story_Points__c = 5, Is_Public__c = true)
    );
    Test.stopTest();

    Assert.areEqual(0, queued, 'Only status, title, start and due are pushed.');
    Assert.areEqual('Failed', syncStatusOf(item.Id), 'Nothing staged.');
  }

  @IsTest
  static void twoHundredStatusChangesCostOneJob() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    List<Work_Item__c> items = TestDataFactory.createWorkItems(
      200,
      project.Id,
      false
    );
    for (Work_Item__c item : items) {
      item.Status__c = 'To Do';
      item.Sync_Status__c = 'Pending';
    }
    insert items;

    List<Work_Item__c> changes = new List<Work_Item__c>();
    for (Work_Item__c item : items) {
      changes.add(new Work_Item__c(Id = item.Id, Status__c = 'In Progress'));
    }

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    update changes;
    Integer queued = Limits.getQueueableJobs() - before;
    Test.stopTest();

    // The job carries the whole list and chunks it itself; the trigger's part is to enqueue
    // once, whatever the volume.
    Assert.areEqual(1, queued, 'One job for the batch, not one per record.');
  }

  /**
   * The rule build 07 step 8 added here, and step 9 took back out.
   *
   * Step 8 made sync inbound-only for anything flagged public, on the reasoning that a public
   * item is a showcase mirror whose remote system owns the truth. That conflated two different
   * questions. Is_Public__c answers who may READ a record - it is the guest board's gate. Who
   * may WRITE it is a permissions question, and the answer does not change because a visitor
   * can see the card.
   *
   * The practical effect was that the internal board's status control silently stopped working
   * on exactly the records the portfolio exists to show off, with no error anywhere. Asserted
   * on a Jira record, because Jira is whose behaviour moved and moved back.
   *
   * This test exists to fail if the clause is ever restored.
   */
  @IsTest
  static void aPublicJiraItemStillPushesOnAStatusChange() {
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.Status__c = WorkItemStatus.TO_DO;
    item.Sync_Status__c = SyncStatus.PENDING;
    item.Is_Public__c = true;
    insert item;

    Test.startTest();
    item.Status__c = WorkItemStatus.IN_PROGRESS;
    update item;
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      1,
      queued,
      'Public means visible, not frozen. If this reads 0, the Is_Public__c clause is back in ' +
      'isPushable and every item on the public board has quietly become read-only.'
    );
  }

  @IsTest
  static void aPrivateJiraItemAlsoPushes() {
    // The same assertion with the flag off, so the one above cannot pass merely because
    // everything pushes regardless of what it is asserting about.
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.Status__c = WorkItemStatus.TO_DO;
    item.Sync_Status__c = SyncStatus.PENDING;
    item.Is_Public__c = false;
    insert item;

    Test.startTest();
    item.Status__c = WorkItemStatus.IN_PROGRESS;
    update item;
    Integer queued = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      1,
      queued,
      'Visibility is not a sync rule in either direction.'
    );
  }

  // ---------- title and dates (build 08) ----------

  @IsTest
  static void aTitleChangeStagesTheTitleAndQueuesOnePush() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = seed('To Do', 'Synced', true);

    Test.startTest();
    Integer queued = jobsQueuedBy(
      new Work_Item__c(Id = item.Id, Title__c = 'Retitled')
    );
    Work_Item__c staged = stagedOf(item.Id);
    Test.stopTest();

    Assert.areEqual(1, queued, 'A title edit reaches the source now.');
    Assert.areEqual('Pending', staged.Sync_Status__c);
    Assert.areEqual(
      'TITLE',
      staged.Pending_Push_Fields__c,
      'Exactly the field that changed, so the push sends nothing else.'
    );
  }

  @IsTest
  static void aChangeOfCaseAloneIsStillAnEdit() {
    Work_Item__c item = seed('To Do', 'Failed', true);

    Test.startTest();
    // Apex compares strings case-insensitively, so this is "no change" to ==.
    Integer queued = jobsQueuedBy(
      new Work_Item__c(Id = item.Id, Title__c = 'SEEDED WORK ITEM 1')
    );
    Test.stopTest();

    Assert.areEqual(
      1,
      queued,
      'Somebody fixed the capitals. That is an edit, and it should reach the source.'
    );
  }

  @IsTest
  static void dateChangesAreStagedAndSecondEditsAccumulate() {
    Work_Item__c item = seed('To Do', 'Synced', true);

    Test.startTest();
    Integer first = jobsQueuedBy(
      new Work_Item__c(
        Id = item.Id,
        Due_Date__c = Date.newInstance(2026, 10, 1)
      )
    );
    Integer second = jobsQueuedBy(
      new Work_Item__c(
        Id = item.Id,
        Start_Date__c = Date.newInstance(2026, 9, 25)
      )
    );
    Work_Item__c staged = stagedOf(item.Id);
    Test.stopTest();

    Assert.areEqual(1, first);
    Assert.areEqual(1, second, 'Each edit queues its own push.');
    Assert.areEqual(
      'START_DATE;DUE_DATE',
      staged.Pending_Push_Fields__c,
      'The second edit adds to the first rather than replacing it - otherwise a quick second ' +
      'save would erase the first before it was pushed.'
    );
  }

  @IsTest
  static void aNewEditClearsTheLastFailuresReason() {
    Work_Item__c item = seed('To Do', 'Failed', true);
    update new Work_Item__c(
      Id = item.Id,
      Sync_Error__c = 'Jira returned 401.',
      Pending_Push_Fields__c = 'STATUS'
    );

    Test.startTest();
    jobsQueuedBy(new Work_Item__c(Id = item.Id, Title__c = 'Retitled'));
    Work_Item__c staged = stagedOf(item.Id);
    Test.stopTest();

    Assert.isNull(
      staged.Sync_Error__c,
      'A new attempt is under way; the old reason no longer describes the record.'
    );
    Assert.areEqual(
      'STATUS;TITLE',
      staged.Pending_Push_Fields__c,
      'And the refused status is still waiting, so this push retries it.'
    );
  }

  @IsTest
  static void anInboundTitleChangeIsNeverPushedBack() {
    Work_Item__c item = seed('To Do', 'Synced', true);

    Test.startTest();
    Integer queued;
    SyncContext.suppressOutbound();
    try {
      queued = jobsQueuedBy(
        new Work_Item__c(
          Id = item.Id,
          Title__c = 'Renamed in Jira',
          Due_Date__c = Date.newInstance(2026, 10, 1)
        )
      );
    } finally {
      SyncContext.resumeOutbound();
    }
    Test.stopTest();

    Assert.areEqual(
      0,
      queued,
      'What came from the source is not sent back to it.'
    );
    Assert.isNull(stagedOf(item.Id).Pending_Push_Fields__c);
  }

  // ---------- the start date rule (build 08) ----------

  private static void rules() {
    BoardSourceRules.reset();
    BoardSourceRules.injected = new List<Board_Source__mdt>{
      new Board_Source__mdt(
        External_System__c = 'Jira',
        Display_Label__c = 'Jira',
        Supports_Start_Date__c = true
      ),
      new Board_Source__mdt(
        External_System__c = 'Asana',
        Display_Label__c = 'Asana',
        Supports_Start_Date__c = false
      )
    };
  }

  @IsTest
  static void aStartDateIsRefusedOnASourceWithoutThemHoweverItArrives() {
    rules();
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.External_System__c = 'Asana';
    item.External_Id__c = 'asana:1210000000000001';
    item.Start_Date__c = Date.newInstance(2026, 9, 1);

    Test.startTest();
    Database.SaveResult inserted = Database.insert(item, false);
    item.Start_Date__c = null;
    insert item;
    Database.SaveResult updated = Database.update(
      new Work_Item__c(
        Id = item.Id,
        Start_Date__c = Date.newInstance(2026, 9, 1)
      ),
      false
    );
    Test.stopTest();

    Assert.isFalse(inserted.isSuccess(), 'Refused on insert.');
    Assert.isTrue(
      inserted.getErrors()[0]
        .getMessage()
        .contains('Asana does not support start dates'),
      inserted.getErrors()[0].getMessage()
    );
    Assert.isFalse(
      updated.isSuccess(),
      'And on update - the record page and the API are not the board, and the rule has to ' +
      'hold for them too.'
    );
  }

  @IsTest
  static void aStartDateIsAcceptedWhereTheSourceHasThem() {
    rules();
    Work_Item__c item = seed('To Do', 'Synced', true);

    Test.startTest();
    Database.SaveResult updated = Database.update(
      new Work_Item__c(
        Id = item.Id,
        Start_Date__c = Date.newInstance(2026, 9, 1)
      ),
      false
    );
    Test.stopTest();

    Assert.isTrue(updated.isSuccess(), String.valueOf(updated.getErrors()));
  }
}
