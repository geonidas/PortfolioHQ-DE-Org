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
  static void aChangeToAnythingButStatusPushesNothing() {
    Work_Item__c item = seed('To Do', 'Failed', true);

    Test.startTest();
    Integer queued = jobsQueuedBy(
      new Work_Item__c(
        Id = item.Id,
        Title__c = 'Retitled',
        Story_Points__c = 5,
        Is_Public__c = true
      )
    );
    Test.stopTest();

    Assert.areEqual(0, queued, 'Only a Status__c change is a reason to sync.');
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
   * The rule that arrived in build 07 step 8 and changed Jira's behaviour as well as Asana's.
   *
   * Sync is bidirectional for private items and inbound-only for public ones. A public item is a
   * showcase mirror: the remote system is its source of truth, and a status typed into
   * Salesforce should not rewrite what the portfolio is showing off. Asserted here, on a Jira
   * record, precisely because the rule is vendor-neutral and it is Jira whose behaviour moved.
   */
  @IsTest
  static void aPublicJiraItemNoLongerPushesOnAStatusChange() {
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
      0,
      queued,
      'Before step 8 this enqueued a real push to a real Jira issue. If a public issue stops ' +
      'responding to a status change made in Salesforce, this is why, and it is intended.'
    );
    Assert.areEqual(
      SyncStatus.PENDING,
      [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id]
      .Sync_Status__c,
      'And the before-update half agrees: nothing was staged either, so the two halves of the ' +
      'trigger cannot drift apart.'
    );
  }

  @IsTest
  static void aPrivateJiraItemStillPushes() {
    // The other half of the same rule, so the assertion above cannot pass because nothing
    // pushes at all.
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

    Assert.areEqual(1, queued, 'A private item is still bidirectional.');
  }
}
