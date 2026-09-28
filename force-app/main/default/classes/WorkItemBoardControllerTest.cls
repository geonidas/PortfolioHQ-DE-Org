/**
 * Board controller: shape, scoping, user mode, bulk safety, and the status change path.
 *
 * The status change tests matter most. Build 03's trigger already pushes on a Status__c change,
 * so the controller's job is to make that change and stay out of the way - pushing twice, or
 * calling the sync service directly, are both silent failures these tests exist to catch.
 */
@IsTest
private class WorkItemBoardControllerTest {
  private static Project__c seedProject(String shortName) {
    Project__c project = TestDataFactory.createProjects(1, false)[0];
    project.Short_Name__c = shortName;
    insert project;
    return project;
  }

  private static List<Work_Item__c> seedItems(
    Integer count,
    Id projectId,
    String status
  ) {
    List<Work_Item__c> items = TestDataFactory.createWorkItems(
      count,
      projectId,
      false
    );
    for (Work_Item__c item : items) {
      item.Status__c = status;
      item.Sync_Status__c = 'Pending';
    }
    insert items;
    return items;
  }

  // ---------- shape and scoping ----------

  @IsTest
  static void returnsItemsProjectAndFreshness() {
    Project__c project = seedProject('PHQ');
    List<Work_Item__c> items = seedItems(3, project.Id, 'To Do');
    Datetime newest = Datetime.now();
    items[1].Last_Synced__c = newest.addHours(-1);
    items[2].Last_Synced__c = newest;
    update items;

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Test.stopTest();

    Assert.areEqual(
      3,
      board.itemCount,
      'Every item in the project should be returned.'
    );
    Assert.areEqual(
      3,
      board.items.size(),
      'Wrapper should carry the records themselves.'
    );
    Assert.areEqual(
      project.Id,
      board.projectId,
      'Scope should be echoed back.'
    );
    Assert.areEqual(
      'PHQ',
      board.projectLabel,
      'Short_Name__c is the intended label.'
    );
    Assert.areEqual(
      newest.getTime() / 1000,
      board.lastSyncedAt.getTime() / 1000,
      'Freshness should be the most recent sync across the set, not the first or last row.'
    );
  }

  @IsTest
  static void projectLabelFallsBackToNameWhenShortNameIsBlank() {
    // The only project in the live org has no Short_Name__c, so this is the real path.
    Project__c project = seedProject(null);
    seedItems(1, project.Id, 'To Do');

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Test.stopTest();

    Assert.areEqual(
      project.Name,
      board.projectLabel,
      'A blank short name must not render an empty label.'
    );
  }

  @IsTest
  static void aBlankProjectMeansEveryItemNotOrphans() {
    Project__c one = seedProject('ONE');
    Project__c two = seedProject('TWO');
    seedItems(2, one.Id, 'To Do');
    seedItems(3, two.Id, 'Done');

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      null
    );
    Test.stopTest();

    Assert.areEqual(
      5,
      board.itemCount,
      'No project id means everything, not items without a project.'
    );
    Assert.isNull(
      board.projectLabel,
      'An unscoped board has no project label.'
    );
    Assert.isNull(board.projectId, 'And no project id.');
  }

  @IsTest
  static void scopingExcludesOtherProjects() {
    Project__c mine = seedProject('MINE');
    Project__c other = seedProject('OTHER');
    seedItems(2, mine.Id, 'To Do');
    seedItems(4, other.Id, 'To Do');

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      mine.Id
    );
    Test.stopTest();

    Assert.areEqual(
      2,
      board.itemCount,
      'Only the scoped project should come back.'
    );
  }

  @IsTest
  static void anEmptyProjectIsNotAnError() {
    Project__c project = seedProject('EMPTY');

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Test.stopTest();

    Assert.areEqual(0, board.itemCount, 'No items is a valid answer.');
    Assert.isNull(
      board.lastSyncedAt,
      'Nothing synced means no freshness, not an exception.'
    );
    Assert.areEqual(
      'EMPTY',
      board.projectLabel,
      'The label still resolves so the empty state can name the project.'
    );
  }

  // ---------- limits ----------

  @IsTest
  static void bulkVolumeCostsAFixedNumberOfQueries() {
    Project__c project = seedProject('BULK');
    seedItems(200, project.Id, 'In Progress');

    Test.startTest();
    Integer before = Limits.getQueries();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    Assert.areEqual(200, board.itemCount, 'All records should return.');
    // One for the work items, one for the project. No per-card query, whatever the volume.
    Assert.areEqual(
      2,
      used,
      'Query count must not scale with the number of records.'
    );
  }

  // ---------- user mode ----------

  @IsTest
  static void queriesRunInUserModeSoAnUnprivilegedUserSeesNothing() {
    Project__c project = seedProject('SECURE');
    seedItems(2, project.Id, 'To Do');

    User restricted;
    // Creating a User alongside custom object DML needs its own context.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile standard = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      restricted = new User(
        ProfileId = standard.Id,
        LastName = 'Restricted',
        Email = 'restricted@example.com',
        Username = 'restricted' +
          DateTime.now().getTime() +
          '@example.com.portfoliohq',
        Alias = 'rstr',
        TimeZoneSidKey = 'GMT',
        LocaleSidKey = 'en_US',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US'
      );
      insert restricted;
    }

    Boolean refused = false;
    Test.startTest();
    System.runAs(restricted) {
      try {
        WorkItemBoardController.getBoardData(project.Id);
      } catch (Exception e) {
        refused = true;
      }
    }
    Test.stopTest();

    // USER_MODE is the whole point: build 05 puts this behind a guest, and a system mode
    // query would have returned these records to a user with no grant at all.
    Assert.isTrue(
      refused,
      'A user without access must not receive board data.'
    );
  }

  // ---------- the record link (build 08 step 7) ----------

  /** A Standard User, optionally holding Portfolio_HQ_Developer. */
  private static User boardUser(String alias, Boolean withDeveloperSet) {
    User created;
    // Creating a User alongside custom object DML needs its own context.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile standard = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      created = new User(
        ProfileId = standard.Id,
        LastName = alias,
        Email = alias + '@example.com',
        Username = alias +
          DateTime.now().getTime() +
          '@example.com.portfoliohq',
        Alias = alias.left(8),
        TimeZoneSidKey = 'GMT',
        LocaleSidKey = 'en_US',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US'
      );
      insert created;
      if (withDeveloperSet) {
        PermissionSet developer = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Portfolio_HQ_Developer'
          LIMIT 1
        ];
        insert new PermissionSetAssignment(
          AssigneeId = created.Id,
          PermissionSetId = developer.Id
        );
      }
    }
    return created;
  }

  @IsTest
  static void theRecordLinkFollowsTheCustomPermission() {
    User developer = boardUser('phqdev', true);
    User other = boardUser('phqother', false);

    WorkItemBoardController.BoardData board;
    Boolean otherMayOpen;
    Test.startTest();
    System.runAs(developer) {
      board = WorkItemBoardController.getBoardData(null);
    }
    System.runAs(other) {
      otherMayOpen = WorkItemBoardController.canOpenRecord();
    }
    Test.stopTest();

    Assert.isTrue(
      board.canOpenRecord,
      'Portfolio_HQ_Developer carries ' +
        WorkItemBoardController.OPEN_RECORD_PERMISSION +
        ', so its holder sees the link.'
    );
    // Asked directly, because a user without the permission set cannot read the board at all
    // and getBoardData would refuse before answering.
    Assert.isFalse(
      otherMayOpen,
      'Without the permission set there is no link: a profile does not grant it.'
    );
  }

  @IsTest
  static void theBoardSaysHowLongATitleMayBe() {
    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      null
    );
    Test.stopTest();

    // The card checks the same limit saveDetails enforces, and says so before it sends.
    Assert.areEqual(WorkItemBoardController.TITLE_MAX, board.titleMaxLength);
  }

  // ---------- retry (build 08 step 8) ----------

  private static Work_Item__c failedItem(String shortName) {
    Project__c project = seedProject(shortName);
    Work_Item__c item = seedItems(1, project.Id, 'To Do')[0];
    update new Work_Item__c(
      Id = item.Id,
      Sync_Status__c = 'Failed',
      Sync_Error__c = 'Jira returned 503.',
      Pending_Push_Fields__c = 'STATUS'
    );
    return item;
  }

  @IsTest
  static void retryQueuesOnePushThroughTheTrigger() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = failedItem('RETRY');

    Test.startTest();
    Integer jobsBefore = Limits.getQueueableJobs();
    WorkItemBoardController.StatusChangeResult result = WorkItemBoardController.retryPush(
      item.Id
    );
    Integer queued = Limits.getQueueableJobs() - jobsBefore;
    Test.stopTest();

    Assert.isTrue(result.pushQueued);
    Assert.areEqual(
      1,
      queued,
      'One push, queued by the trigger. The controller calls no sync service.'
    );
    Assert.areEqual(
      'Pending',
      result.syncStatus,
      'Pending until the source confirms, as for any save.'
    );
    Assert.isTrue(
      result.message.contains('Jira') && result.message.contains('again'),
      result.message
    );
  }

  @IsTest
  static void retryOnARecordThatIsNotFailedWritesNothing() {
    Project__c project = seedProject('NOFAIL');
    Work_Item__c item = seedItems(1, project.Id, 'To Do')[0];

    Test.startTest();
    Integer jobsBefore = Limits.getQueueableJobs();
    WorkItemBoardController.StatusChangeResult result = WorkItemBoardController.retryPush(
      item.Id
    );
    Integer queued = Limits.getQueueableJobs() - jobsBefore;
    Test.stopTest();

    Assert.isFalse(result.pushQueued);
    Assert.areEqual(0, queued);
    Assert.isTrue(
      result.message.startsWith('Nothing to retry'),
      result.message
    );
  }

  @IsTest
  static void retryOnARecordWithNoRemoteRecordSaysSo() {
    Work_Item__c item = failedItem('LOCALRETRY');
    update new Work_Item__c(Id = item.Id, External_Id__c = null);

    Test.startTest();
    WorkItemBoardController.StatusChangeResult result = WorkItemBoardController.retryPush(
      item.Id
    );
    Test.stopTest();

    Assert.isFalse(result.pushQueued);
    Assert.isTrue(result.message.contains('nothing to send'), result.message);
  }

  // ---------- status change ----------

  @IsTest
  static void statusChangeWritesLocallyAndQueuesExactlyOnePush() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Project__c project = seedProject('PUSH');
    Work_Item__c item = seedItems(1, project.Id, 'To Do')[0];

    Test.startTest();
    Integer jobsBefore = Limits.getQueueableJobs();
    WorkItemBoardController.StatusChangeResult result = WorkItemBoardController.changeStatus(
      item.Id,
      'In Progress'
    );
    Integer queued = Limits.getQueueableJobs() - jobsBefore;
    Test.stopTest();

    Assert.areEqual(
      'In Progress',
      result.status,
      'The local change should be applied.'
    );
    Assert.isTrue(
      result.pushQueued,
      'The trigger should have queued an outbound push.'
    );
    // The controller must not push as well as the trigger. Two jobs means two callout pairs,
    // and the second would find no transition and mark the record Failed.
    Assert.areEqual(
      1,
      queued,
      'Exactly one outbound push, queued by the trigger and nobody else.'
    );
    Assert.areEqual(
      'In Progress',
      [SELECT Status__c FROM Work_Item__c WHERE Id = :item.Id].Status__c,
      'The record should be updated.'
    );
  }

  @IsTest
  static void statusChangeReportsPendingRatherThanClaimingJiraAgreed() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Project__c project = seedProject('HONEST');
    Work_Item__c item = seedItems(1, project.Id, 'To Do')[0];

    Test.startTest();
    WorkItemBoardController.StatusChangeResult result = WorkItemBoardController.changeStatus(
      item.Id,
      'Done'
    );

    // Before the queued job runs, the record must not claim to be reconciled.
    Assert.areEqual(
      'Pending',
      result.syncStatus,
      'Sync status should read Pending while the push is queued.'
    );
    Assert.isTrue(
      result.message.contains('background'),
      'The message should say the push is asynchronous.'
    );
    Test.stopTest();
  }

  @IsTest
  static void statusChangeIsANoOpWhenAlreadyInTheTargetStatus() {
    Project__c project = seedProject('NOOP');
    Work_Item__c item = seedItems(1, project.Id, 'To Do')[0];

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    WorkItemBoardController.StatusChangeResult result = WorkItemBoardController.changeStatus(
      item.Id,
      'To Do'
    );
    Integer queued = Limits.getQueueableJobs() - before;
    Test.stopTest();

    Assert.isFalse(
      result.pushQueued,
      'Nothing changed, so nothing should be pushed.'
    );
    Assert.areEqual(0, queued, 'A no-op must not cost a callout.');
    Assert.isTrue(
      result.message.contains('Nothing was changed'),
      'And should say so: ' + result.message
    );
  }

  @IsTest
  static void statusChangeRefusesUnspecified() {
    Project__c project = seedProject('REFUSE');
    Work_Item__c item = seedItems(1, project.Id, 'To Do')[0];

    Test.startTest();
    try {
      WorkItemBoardController.changeStatus(item.Id, 'Unspecified');
      Assert.fail('Unspecified means no Jira mapping; it cannot be a target.');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage(), 'Should explain itself.');
    }
    Test.stopTest();
  }

  @IsTest
  static void statusChangeRefusesMissingArguments() {
    Test.startTest();
    for (Integer i = 0; i < 2; i++) {
      try {
        if (i == 0) {
          WorkItemBoardController.changeStatus(null, 'Done');
        } else {
          Project__c project = seedProject('ARGS');
          WorkItemBoardController.changeStatus(
            seedItems(1, project.Id, 'To Do')[0].Id,
            '   '
          );
        }
        Assert.fail('Missing arguments should be refused, case ' + i);
      } catch (AuraHandledException e) {
        Assert.isNotNull(e.getMessage(), 'Should explain itself.');
      }
    }
    Test.stopTest();
  }

  // ---------- selectors ----------

  @IsTest
  static void selectorsHandleEmptyAndNullInput() {
    Test.startTest();
    Assert.areEqual(
      0,
      WorkItemSelector.byIds(null).size(),
      'Null ids is a no-op.'
    );
    Assert.areEqual(
      0,
      WorkItemSelector.byIds(new Set<Id>()).size(),
      'Empty ids is a no-op.'
    );
    Assert.isNull(
      ProjectSelector.byId(null),
      'A null project id resolves to no project.'
    );
    Assert.isNull(ProjectSelector.labelFor(null), 'And to no label.');
    Test.stopTest();
  }

  // ---------- saving title and dates (build 08) ----------

  private static Work_Item__c jiraItem() {
    Project__c project = seedProject('EDIT');
    Work_Item__c item = seedItems(1, project.Id, 'In Progress')[0];
    // Synced, so a Pending after the save can only have come from the save.
    SyncContext.suppressOutbound();
    try {
      update new Work_Item__c(Id = item.Id, Sync_Status__c = 'Synced');
    } finally {
      SyncContext.resumeOutbound();
    }
    return item;
  }

  private static Work_Item__c asanaItem() {
    Project__c project = seedProject('LEARN');
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.External_System__c = 'Asana';
    item.External_Id__c = 'asana:1210000000000077';
    item.Status__c = 'In Progress';
    insert item;
    return item;
  }

  private static Work_Item__c reread(Id itemId) {
    return [
      SELECT
        Title__c,
        Start_Date__c,
        Due_Date__c,
        Sync_Status__c,
        Pending_Push_Fields__c
      FROM Work_Item__c
      WHERE Id = :itemId
    ];
  }

  @IsTest
  static void savingWritesOnlyWhatChangedAndLeavesItPending() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      '  Render work items on the board  ',
      '',
      '2026-10-01',
      null
    );
    Work_Item__c staged = reread(item.Id);
    Test.stopTest();

    Assert.isTrue(result.saved, result.message);
    Assert.isTrue(
      result.fieldErrors.isEmpty(),
      String.valueOf(result.fieldErrors)
    );
    Assert.isTrue(result.pushQueued, 'The trigger queued the push.');
    Assert.areEqual(
      'Pending',
      result.syncStatus,
      'Saved in Salesforce, not yet in Jira - and the result says which.'
    );
    Assert.isTrue(
      result.message.contains('The Jira update is running in the background'),
      'Named from the source label: ' + result.message
    );
    Assert.areEqual(
      'Render work items on the board',
      staged.Title__c,
      'Trimmed.'
    );
    Assert.areEqual(Date.newInstance(2026, 10, 1), staged.Due_Date__c);
    Assert.areEqual(
      'TITLE;DUE_DATE',
      staged.Pending_Push_Fields__c,
      'The start date did not change, so it is not pushed.'
    );
  }

  @IsTest
  static void aUserEditPushesExactlyOnce() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.saveDetails(item.Id, 'Retitled', '', '', null);
    Test.stopTest(); // runs the queued push

    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE ApexClass.Name = 'WorkItemSyncQueueable'
      ],
      'One push. The sync\'s own write-back changes no pushable field, so it queues nothing.'
    );
    Assert.areEqual(
      2,
      mock.callCount(),
      'One PUT, then the read of Jira\'s updated timestamp; nothing else.'
    );
    Assert.areEqual('PUT', mock.captured[0].method);
    Work_Item__c after = reread(item.Id);
    Assert.areEqual('Synced', after.Sync_Status__c, 'Jira confirmed it.');
    Assert.isNull(after.Pending_Push_Fields__c);
  }

  @IsTest
  static void aStartDateIsRefusedForASourceWithoutThem() {
    Work_Item__c item = asanaItem();

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Seeded work item 1',
      '2026-09-01',
      '',
      null
    );
    Test.stopTest();

    Assert.isFalse(result.saved);
    Assert.isTrue(
      result.fieldErrors.get('startDate')
        .contains('Asana does not support start dates'),
      'Refused here, not only hidden in the component: ' + result.fieldErrors
    );
    Assert.isNull(reread(item.Id).Start_Date__c, 'Nothing was written.');
  }

  @IsTest
  static void aStartAfterTheDueIsRefused() {
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Seeded work item 1',
      '2026-10-05',
      '2026-10-01',
      null
    );
    Test.stopTest();

    Assert.isFalse(result.saved);
    String message = result.fieldErrors.get('startDate');
    Assert.isTrue(
      message.contains('2026-10-05') && message.contains('2026-10-01'),
      'Says which dates and what to do: ' + message
    );
  }

  @IsTest
  static void anEmptyOrOverLongTitleIsRefused() {
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.DetailSaveResult empty = WorkItemBoardController.saveDetails(
      item.Id,
      '    ',
      '',
      '',
      null
    );
    WorkItemBoardController.DetailSaveResult tooLong = WorkItemBoardController.saveDetails(
      item.Id,
      'x'.repeat(WorkItemBoardController.TITLE_MAX + 1),
      '',
      '',
      null
    );
    Test.stopTest();

    Assert.isFalse(empty.saved);
    Assert.isTrue(empty.fieldErrors.get('title').contains('required'));
    Assert.isFalse(tooLong.saved);
    Assert.isTrue(
      tooLong.fieldErrors.get('title').contains('256') &&
      tooLong.fieldErrors.get('title').contains('255'),
      'Says how long it is and what the limit is: ' +
      tooLong.fieldErrors.get('title')
    );
    Assert.areEqual(
      'Seeded work item 1',
      reread(item.Id).Title__c,
      'Neither was written.'
    );
  }

  @IsTest
  static void anImpossibleDateIsRefusedRatherThanRolledOver() {
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Seeded work item 1',
      '',
      '2026-02-30',
      null
    );
    Test.stopTest();

    Assert.isFalse(result.saved);
    Assert.isTrue(result.fieldErrors.containsKey('dueDate'));
    Assert.isNull(
      reread(item.Id).Due_Date__c,
      'Not quietly saved as the second of March.'
    );
  }

  @IsTest
  static void savingWithNothingChangedWritesNothing() {
    Work_Item__c item = jiraItem();

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Seeded work item 1',
      '',
      '',
      null
    );
    Integer queued = Limits.getQueueableJobs() - before;
    Test.stopTest();

    Assert.isFalse(result.saved);
    Assert.isFalse(result.pushQueued);
    Assert.areEqual(0, queued);
    Assert.areEqual('Synced', reread(item.Id).Sync_Status__c);
  }

  @IsTest
  static void saveDetailsRefusesAMissingId() {
    try {
      WorkItemBoardController.saveDetails(null, 'Title', '', '', null);
      Assert.fail('A missing id should be refused.');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  // ---------- the card payload (build 08 step 5) ----------

  private static WorkItemBoardController.BoardCard cardNamed(
    WorkItemBoardController.BoardData board,
    Id itemId
  ) {
    for (WorkItemBoardController.BoardCard card : board.items) {
      if (card.id == itemId) {
        return card;
      }
    }
    return null;
  }

  @IsTest
  static void cardsCarryTheSameFactsAsThePublicBoardPlusTheirOwn() {
    Work_Item__c jira = jiraItem();
    SyncContext.suppressOutbound();
    try {
      update new Work_Item__c(
        Id = jira.Id,
        Source_Created__c = Datetime.newInstanceGmt(2026, 9, 8, 12, 0, 0),
        Start_Date__c = Date.newInstance(2026, 9, 21),
        Due_Date__c = Date.newInstance(2026, 10, 1),
        Sync_Status__c = 'Failed',
        Sync_Error__c = 'Jira returned 401.',
        Type__c = 'Unspecified'
      );
    } finally {
      SyncContext.resumeOutbound();
    }
    Work_Item__c asana = asanaItem();

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      null
    );
    Test.stopTest();

    WorkItemBoardController.BoardCard j = cardNamed(board, jira.Id);
    Assert.areEqual('Jira', j.sourceLabel);
    Assert.areEqual('accent-1', j.accentToken);
    Assert.isTrue(j.supportsStartDate);
    Assert.isTrue(j.condensesIntoEpic);
    Assert.areEqual('2026-09-21', j.startDate);
    Assert.areEqual('2026-10-01', j.dueDate);
    Assert.areEqual(Datetime.newInstanceGmt(2026, 9, 8, 12, 0, 0), j.createdAt);
    Assert.areEqual('Failed', j.syncStatus);
    Assert.areEqual(
      'Jira returned 401.',
      j.syncError,
      'The reason travels with the card, internal board only.'
    );
    Assert.isNull(
      j.type,
      'An unmapped type is null here, as on the public board.'
    );

    WorkItemBoardController.BoardCard a = cardNamed(board, asana.Id);
    Assert.areEqual('Asana', a.sourceLabel);
    Assert.areEqual('accent-2', a.accentToken);
    Assert.isFalse(
      a.supportsStartDate,
      'So the card offers no start date editor.'
    );
    Assert.isFalse(a.condensesIntoEpic);
  }

  @IsTest
  static void aRecordThatCanNeverPushShowsNoSyncState() {
    // The seed canary WI-0011: no External_Id__c, so nothing can ever push it, and it showed
    // Pending from the day it was seeded. Pending means "waiting for the source", and nothing
    // was waiting.
    Project__c project = seedProject('LOCAL');
    Work_Item__c local = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    local.External_Id__c = null;
    local.Status__c = 'In Progress';
    local.Sync_Status__c = 'Pending';
    insert local;

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Test.stopTest();

    Assert.isNull(board.items[0].syncStatus);
  }

  @IsTest
  static void theEpicViewUsesTheSameRulesAsThePublicBoard() {
    Project__c project = seedProject('EPICS');
    project.Is_Public__c = true;
    update project;
    Work_Item__c epic = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    epic.Type__c = 'Epic';
    epic.Status__c = 'In Progress';
    epic.Is_Public__c = true;
    insert epic;
    List<Work_Item__c> children = TestDataFactory.createWorkItems(
      3,
      project.Id,
      false
    );
    for (Integer i = 0; i < children.size(); i++) {
      children[i].Type__c = 'Story';
      children[i].Status__c = i == 0 ? 'Done' : 'To Do';
      children[i].Parent_Work_Item__c = epic.Id;
      children[i].Is_Public__c = true;
    }
    insert children;

    Test.startTest();
    WorkItemBoardController.BoardData internal = WorkItemBoardController.getBoardData(
      project.Id
    );
    PublicBoardController.PublicBoardData guest = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Assert.areEqual(1, internal.epics.size());
    Assert.areEqual(1, guest.epics.size());
    Assert.areEqual(
      guest.epics[0].totalChildren,
      internal.epics[0].totalChildren,
      'One rule, one piece of code: the two boards cannot disagree about an epic.'
    );
    Assert.areEqual(
      guest.epics[0].completedChildren,
      internal.epics[0].completedChildren
    );
    Assert.areEqual(3, internal.epics[0].totalChildren);
    Assert.areEqual(1, internal.epics[0].completedChildren);
    Assert.areEqual(
      epic.Id,
      internal.epics[0].id,
      'Internal epics keep their id.'
    );
    Assert.areEqual(
      4,
      internal.items.size(),
      'The internal task view keeps every card, the epic included.'
    );
  }

  // ---------- saving a priority (build 09) ----------

  private static Work_Item__c withPriority(String priority) {
    Work_Item__c item = jiraItem();
    SyncContext.suppressOutbound();
    try {
      update new Work_Item__c(Id = item.Id, Priority__c = priority);
    } finally {
      SyncContext.resumeOutbound();
    }
    return item;
  }

  private static Work_Item__c priorityOf(Id itemId) {
    return [
      SELECT Priority__c, Title__c, Sync_Status__c, Pending_Push_Fields__c
      FROM Work_Item__c
      WHERE Id = :itemId
    ];
  }

  @IsTest
  static void aPriorityIsSavedAndStagedAlone() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Seeded work item 1',
      '',
      '',
      'high'
    );
    Work_Item__c staged = priorityOf(item.Id);
    Test.stopTest();

    Assert.isTrue(result.saved, result.message);
    Assert.isTrue(result.pushQueued, 'The trigger queued the push.');
    Assert.areEqual(
      'High',
      staged.Priority__c,
      'Stored in the picklist\'s own spelling, whatever case it arrived in.'
    );
    Assert.areEqual(
      'PRIORITY',
      staged.Pending_Push_Fields__c,
      'Only the priority waits to push.'
    );
    Assert.areEqual('Pending', staged.Sync_Status__c);
  }

  @IsTest
  static void aNullPriorityLeavesItAloneWhateverElseIsSaved() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = withPriority('Medium');

    Test.startTest();
    // What the card before build 09 sends - and a board left open from before an update.
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Retitled',
      '',
      '',
      null
    );
    Work_Item__c staged = priorityOf(item.Id);
    Test.stopTest();

    Assert.isTrue(result.saved, result.message);
    Assert.areEqual(
      'Medium',
      staged.Priority__c,
      'Not sent is not none. Read as none, every title edit from an older card would clear ' +
      'the priority and push the en dash to Jira.'
    );
    Assert.areEqual('TITLE', staged.Pending_Push_Fields__c);
  }

  @IsTest
  static void aBlankPriorityClearsItAndPushes() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = withPriority('Medium');

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Seeded work item 1',
      '',
      '',
      ''
    );
    Work_Item__c staged = priorityOf(item.Id);
    Test.stopTest();

    Assert.isTrue(result.saved, result.message);
    Assert.isNull(staged.Priority__c, 'Blank is the explicit none.');
    Assert.areEqual('PRIORITY', staged.Pending_Push_Fields__c);
  }

  @IsTest
  static void aTitleAndPrioritySavedTogetherGoOutInOneCall() {
    FieldMappingService.reset();
    FieldMappingService.injected = JiraWebhookPayloadFactory.priorityMappings();
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.saveDetails(item.Id, 'Retitled', '', '', 'Low');
    Test.stopTest(); // runs the queued push

    Assert.areEqual(
      2,
      mock.callCount(),
      'One save, one job, one PUT - and the timestamp read after it.'
    );
    Map<String, Object> fields = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        mock.captured[0].body
      ))
      .get('fields');
    Assert.areEqual(new Set<String>{ 'summary', 'priority' }, fields.keySet());
    Assert.areEqual(
      '4',
      ((Map<String, Object>) fields.get('priority')).get('id'),
      'Low, by id.'
    );
    Work_Item__c after = priorityOf(item.Id);
    Assert.areEqual('Synced', after.Sync_Status__c, 'Jira confirmed both.');
    Assert.isNull(after.Pending_Push_Fields__c);
  }

  @IsTest
  static void anUnknownPriorityIsAFieldErrorAndSavesNothing() {
    Work_Item__c item = withPriority('Medium');

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Retitled',
      '',
      '',
      'Urgent'
    );
    Test.stopTest();

    Assert.isFalse(result.saved);
    String error = result.fieldErrors.get('priority');
    Assert.isNotNull(error, String.valueOf(result.fieldErrors));
    Assert.isTrue(
      error.contains('"Urgent"') && error.contains('No priority'),
      'Names what was sent and how to fix it, from the picklist: ' + error
    );
    Assert.areEqual(
      'Seeded work item 1',
      priorityOf(item.Id).Title__c,
      'Nothing saved.'
    );
  }

  @IsTest
  static void aPriorityOnASourceWithoutOneIsRefused() {
    BoardSourceRules.reset();
    BoardSourceRules.injected = new List<Board_Source__mdt>{
      new Board_Source__mdt(
        External_System__c = 'Jira',
        Display_Label__c = 'Jira',
        Supports_Priority__c = false
      )
    };
    Work_Item__c item = jiraItem();

    Test.startTest();
    WorkItemBoardController.DetailSaveResult result = WorkItemBoardController.saveDetails(
      item.Id,
      'Seeded work item 1',
      '',
      '',
      'High'
    );
    Test.stopTest();

    Assert.isFalse(result.saved);
    Assert.isTrue(
      result.fieldErrors.get('priority').contains('does not hold a priority'),
      String.valueOf(result.fieldErrors)
    );
  }

  @IsTest
  static void anInternalCardCarriesPriorityRankAndWhetherItCanEditOne() {
    Project__c project = seedProject('PRI');
    Work_Item__c item = seedItems(1, project.Id, 'To Do')[0];
    SyncContext.suppressOutbound();
    try {
      update new Work_Item__c(Id = item.Id, Priority__c = 'Low');
    } finally {
      SyncContext.resumeOutbound();
    }

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Test.stopTest();

    WorkItemBoardController.BoardCard card = board.items[0];
    Assert.areEqual('Low', card.priority);
    Assert.areEqual(
      3,
      card.priorityRank,
      'Third in the picklist, so third in the sort.'
    );
    Assert.isTrue(
      card.supportsPriority,
      'From Board_Source__mdt: the editor reads this, never the source\'s name.'
    );
  }

  @IsTest
  static void theBoardCarriesThePriorityChoicesInOrder() {
    Project__c project = seedProject('OPT');
    seedItems(1, project.Id, 'To Do');

    Test.startTest();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Test.stopTest();

    Assert.areEqual(3, board.priorityOptions.size());
    for (Integer i = 0; i < board.priorityOptions.size(); i++) {
      Assert.areEqual(i + 1, board.priorityOptions[i].rank);
    }
  }

  // ---------- the featured epic (build 10 step 2) ----------

  private static List<Work_Item__c> seedEpics(
    Id projectId,
    Integer count,
    String status
  ) {
    List<Work_Item__c> epics = TestDataFactory.createWorkItems(
      count,
      projectId,
      false
    );
    for (Work_Item__c e : epics) {
      e.Type__c = 'Epic';
      e.Status__c = status;
      e.Is_Public__c = true;
    }
    insert epics;
    return epics;
  }

  private static Project__c publicProject(String shortName) {
    Project__c project = seedProject(shortName);
    project.Is_Public__c = true;
    update project;
    return project;
  }

  @IsTest
  static void theBoardSaysWhichEpicIsFeaturedAtNoExtraQuery() {
    Project__c project = publicProject('FEAT');
    List<Work_Item__c> epics = seedEpics(project.Id, 2, 'In Progress');
    FeaturedEpicService.feature(epics[0].Id);

    Test.startTest();
    Integer before = Limits.getQueries();
    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    Assert.areEqual(epics[0].Id, board.featuredEpicId);
    Assert.areEqual(2, board.epics.size());
    for (WorkItemBoardController.BoardEpic e : board.epics) {
      Assert.areEqual(e.id == epics[0].Id, e.isFeatured, 'Epic ' + e.id);
    }
    Assert.areEqual(
      2,
      used,
      'Items and project, as before: the setting is read from the cache.'
    );
  }

  /** The indicator here never claims what the public board cannot show. */
  @IsTest
  static void anEpicThePublicBoardCannotShowIsNotFeaturedHereEither() {
    Project__c project = publicProject('FEAT');
    List<Work_Item__c> epics = seedEpics(project.Id, 1, 'In Progress');

    WorkItemBoardController.BoardData none = WorkItemBoardController.getBoardData(
      project.Id
    );
    Assert.isNull(none.featuredEpicId, 'None featured.');
    Assert.isFalse(none.epics[0].isFeatured, 'False, never null.');

    FeaturedEpicService.feature(epics[0].Id);
    update new Work_Item__c(Id = epics[0].Id, Is_Public__c = false);
    WorkItemBoardController.BoardData unpublished = WorkItemBoardController.getBoardData(
      project.Id
    );
    Assert.isNull(unpublished.featuredEpicId);
    Assert.isFalse(unpublished.epics[0].isFeatured);
  }

  /**
   * Featured and Done, past the cap of three finished epics: still listed, so step 3's Remove
   * button stays reachable (step 0, question 3).
   */
  @IsTest
  static void aFeaturedDoneEpicKeepsItsCardHere() {
    Project__c project = publicProject('DONE');
    List<Work_Item__c> epics = seedEpics(project.Id, 5, 'Done');
    FeaturedEpicService.feature(epics[4].Id);

    WorkItemBoardController.BoardData board = WorkItemBoardController.getBoardData(
      project.Id
    );

    Boolean listed = false;
    for (WorkItemBoardController.BoardEpic e : board.epics) {
      if (e.id == epics[4].Id) {
        listed = e.isFeatured;
      }
    }
    Assert.isTrue(listed, 'The featured epic is listed, and marked.');
    Assert.isTrue(
      board.epics.size() <= 4,
      'Three finished epics plus the featured one at most: ' +
      board.epics.size()
    );
  }

  // ---------- featuring an epic from the board (build 10 step 3) ----------

  @IsTest
  static void theFeatureButtonFollowsTheCustomPermission() {
    User developer = boardUser('phqfeat', true);
    User other = boardUser('phqnofe', false);

    WorkItemBoardController.BoardData board;
    Boolean otherMayFeature;
    Test.startTest();
    System.runAs(developer) {
      board = WorkItemBoardController.getBoardData(null);
    }
    System.runAs(other) {
      otherMayFeature = WorkItemBoardController.canFeatureEpic();
    }
    Test.stopTest();

    Assert.isTrue(
      board.canFeatureEpic,
      'Portfolio_HQ_Developer carries ' +
        WorkItemBoardController.FEATURE_EPIC_PERMISSION +
        ', so its holder sees the button.'
    );
    Assert.isFalse(otherMayFeature, 'A profile does not grant it.');
  }

  /**
   * Through the board's own methods, as a user holding the permission set: feature, replace, a
   * Remove pressed on a card that is no longer the featured one, and a Remove that clears. No push
   * is queued and no work item is touched at any point.
   */
  @IsTest
  static void theBoardFeaturesReplacesAndRemoves() {
    User developer = boardUser('phqfeat', true);
    Project__c project = publicProject('FEAT');
    List<Work_Item__c> epics = seedEpics(project.Id, 2, 'In Progress');
    Map<Id, String> names = new Map<Id, String>();
    for (Work_Item__c e : [SELECT Id, Name FROM Work_Item__c]) {
      names.put(e.Id, e.Name);
    }
    Id a = epics[0].Id;
    Id b = epics[1].Id;

    FeaturedEpicService.Result first;
    FeaturedEpicService.Result second;
    FeaturedEpicService.Result stale;
    FeaturedEpicService.Result removed;
    Integer jobs;
    Test.startTest();
    jobs = Limits.getQueueableJobs();
    System.runAs(developer) {
      first = WorkItemBoardController.featureEpic(a);
      second = WorkItemBoardController.featureEpic(b);
      stale = WorkItemBoardController.unfeatureEpic(a);
      Assert.areEqual(
        b,
        FeaturedEpicService.read(),
        'A stale Remove changes nothing.'
      );
      removed = WorkItemBoardController.unfeatureEpic(b);
    }
    Assert.areEqual(jobs, Limits.getQueueableJobs(), 'No push was queued.');
    Test.stopTest();

    Assert.isTrue(first.saved, first.message);
    Assert.isTrue(second.saved, second.message);
    Assert.isTrue(
      second.message.contains('in place of ' + names.get(a)),
      second.message
    );
    Assert.isFalse(stale.saved);
    Assert.isFalse(stale.refused, 'Already as asked: news, not an error.');
    Assert.areEqual(
      names.get(a) +
        ' is not featured on the public board, so nothing was changed. ' +
        names.get(b) +
        ' is.',
      stale.message
    );
    Assert.isTrue(removed.saved, removed.message);
    Assert.isNull(FeaturedEpicService.read());
    for (Work_Item__c e : [
      SELECT Sync_Status__c, Pending_Push_Fields__c
      FROM Work_Item__c
    ]) {
      Assert.isNull(e.Pending_Push_Fields__c, 'Nothing staged.');
      Assert.areEqual('Pending', e.Sync_Status__c, 'As seeded: untouched.');
    }
  }

  @IsTest
  static void aRefusalComesBackAsAResultWithItsReason() {
    User developer = boardUser('phqfeat', true);
    Project__c project = publicProject('FEAT');
    Work_Item__c story = seedItems(1, project.Id, 'To Do')[0];

    FeaturedEpicService.Result result;
    Test.startTest();
    System.runAs(developer) {
      result = WorkItemBoardController.featureEpic(story.Id);
    }
    Test.stopTest();

    Assert.isFalse(result.saved);
    Assert.isTrue(result.refused, 'Shown as an error on the card.');
    Assert.isTrue(result.message.contains('is not an epic'), result.message);
  }

  /** The permission is the rule, not the hidden button: both methods refuse without it. */
  @IsTest
  static void withoutThePermissionNeitherMethodChangesAnything() {
    User other = boardUser('phqnofe', false);
    Project__c project = publicProject('FEAT');
    List<Work_Item__c> epics = seedEpics(project.Id, 1, 'In Progress');
    FeaturedEpicService.feature(epics[0].Id);

    List<String> messages = new List<String>();
    Test.startTest();
    System.runAs(other) {
      try {
        WorkItemBoardController.featureEpic(epics[0].Id);
      } catch (AuraHandledException e) {
        messages.add(e.getMessage());
      }
      try {
        WorkItemBoardController.unfeatureEpic(epics[0].Id);
      } catch (AuraHandledException e) {
        messages.add(e.getMessage());
      }
    }
    Test.stopTest();

    Assert.areEqual(
      new List<String>{
        WorkItemBoardController.FEATURE_EPIC_DENIED,
        WorkItemBoardController.FEATURE_EPIC_DENIED
      },
      messages
    );
    Assert.areEqual(epics[0].Id, FeaturedEpicService.read(), 'Still featured.');
  }
}
