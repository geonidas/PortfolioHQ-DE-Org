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
}
