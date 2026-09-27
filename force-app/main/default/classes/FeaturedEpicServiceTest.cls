/**
 * The featured epic's service: set, replace, clear, what is refused and why, what reads as none,
 * and - the guards - that featuring an epic never touches a work item, never queues a push and
 * never stages a field (ADR build-10, decision 2).
 *
 * Every work item here carries an External_Id__c and a known status, so a write to one of them
 * would reach WorkItemTrigger exactly as a real edit does. The guards were each proved by planting
 * a work item write in FeaturedEpicService and watching them fail (build 10 step 1).
 */
@IsTest
private class FeaturedEpicServiceTest {
  @TestSetup
  static void setup() {
    List<Project__c> projects = TestDataFactory.createProjects(2, false);
    projects[0].Is_Public__c = true;
    projects[1].Is_Public__c = false;
    insert projects;
    Id publicProject = projects[0].Id;
    Id privateProject = projects[1].Id;

    List<Work_Item__c> items = new List<Work_Item__c>{
      item('EPIC-A', 'Epic', 'In Progress', true, publicProject),
      item('EPIC-B', 'Epic', 'Done', true, publicProject),
      item('STORY', 'Story', 'To Do', true, publicProject),
      item('UNTYPED', 'Unspecified', 'To Do', true, publicProject),
      item('PRIVATE-EPIC', 'Epic', 'In Progress', false, publicProject),
      item('HIDDEN-PROJECT-EPIC', 'Epic', 'In Progress', true, privateProject),
      item('NO-PROJECT-EPIC', 'Epic', 'In Progress', true, null)
    };
    insert items;
  }

  private static Work_Item__c item(
    String key,
    String type,
    String status,
    Boolean isPublic,
    Id projectId
  ) {
    Work_Item__c row = TestDataFactory.createWorkItems(1, projectId, false)[0];
    row.External_Key__c = key;
    row.Type__c = type;
    row.Status__c = status;
    row.Sync_Status__c = 'Synced';
    row.Is_Public__c = isPublic;
    return row;
  }

  private static Id idOf(String key) {
    return [SELECT Id FROM Work_Item__c WHERE External_Key__c = :key].Id;
  }

  private static String nameOf(String key) {
    return [SELECT Name FROM Work_Item__c WHERE External_Key__c = :key].Name;
  }

  private static Map<Id, Work_Item__c> snapshot() {
    return new Map<Id, Work_Item__c>(
      [
        SELECT
          Id,
          Title__c,
          Status__c,
          Type__c,
          Priority__c,
          Is_Public__c,
          Sync_Status__c,
          Sync_Error__c,
          Pending_Push_Fields__c,
          LastModifiedDate
        FROM Work_Item__c
      ]
    );
  }

  // ---------- set, replace, clear ----------

  @IsTest
  static void featuringAnEpicStoresItsIdAsTheOrgDefault() {
    Id epic = idOf('EPIC-A');

    FeaturedEpicService.Result result = FeaturedEpicService.feature(epic);

    Assert.isTrue(result.saved, result.message);
    Assert.areEqual(
      nameOf('EPIC-A') +
      ' is featured on the public board. Open public boards show it within about 30 seconds.',
      result.message
    );
    Featured_Epic__c setting = Featured_Epic__c.getOrgDefaults();
    Assert.areEqual(UserInfo.getOrganizationId(), setting.SetupOwnerId);
    Assert.areEqual(String.valueOf(epic), setting.Epic_Id__c);
    Assert.areEqual(epic, FeaturedEpicService.storedId());
    Assert.areEqual(epic, FeaturedEpicService.read());
  }

  @IsTest
  static void featuringASecondEpicReplacesTheFirst() {
    FeaturedEpicService.feature(idOf('EPIC-A'));

    FeaturedEpicService.Result result = FeaturedEpicService.feature(
      idOf('EPIC-B')
    );

    Assert.isTrue(result.saved, result.message);
    Assert.isTrue(
      result.message.contains('in place of ' + nameOf('EPIC-A')),
      'The message names the epic it replaced: ' + result.message
    );
    Assert.areEqual(idOf('EPIC-B'), FeaturedEpicService.read());
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Featured_Epic__c],
      'One featured epic by construction: replacing updates the org default, never adds a row.'
    );
  }

  @IsTest
  static void featuringTheFeaturedEpicAgainChangesNothing() {
    FeaturedEpicService.feature(idOf('EPIC-A'));

    Integer rows = Limits.getDmlRows();
    FeaturedEpicService.Result result = FeaturedEpicService.feature(
      idOf('EPIC-A')
    );

    Assert.isFalse(result.saved);
    Assert.isFalse(result.refused, 'Already as asked: news, not an error.');
    Assert.areEqual(
      nameOf('EPIC-A') +
      ' is already featured on the public board. Nothing was changed.',
      result.message
    );
    Assert.areEqual(rows, Limits.getDmlRows(), 'Nothing to write.');
  }

  /** Decision 10: Done does not unfeature an epic, and a Done epic can be featured. */
  @IsTest
  static void aDoneEpicCanBeFeatured() {
    FeaturedEpicService.Result result = FeaturedEpicService.feature(
      idOf('EPIC-B')
    );

    Assert.isTrue(result.saved, result.message);
    Assert.areEqual(idOf('EPIC-B'), FeaturedEpicService.read());
  }

  @IsTest
  static void clearingLeavesNoEpicFeatured() {
    FeaturedEpicService.feature(idOf('EPIC-A'));

    FeaturedEpicService.Result result = FeaturedEpicService.clear();

    Assert.isTrue(result.saved, result.message);
    Assert.areEqual(
      nameOf('EPIC-A') +
      ' is no longer featured on the public board. Open public boards show that within about 30 seconds.',
      result.message
    );
    Assert.isNull(FeaturedEpicService.storedId());
    Assert.isNull(FeaturedEpicService.read());
  }

  @IsTest
  static void clearingWithNothingFeaturedChangesNothing() {
    Integer rows = Limits.getDmlRows();

    FeaturedEpicService.Result result = FeaturedEpicService.clear();

    Assert.isFalse(result.saved);
    Assert.areEqual(
      'No epic is featured, so nothing was changed.',
      result.message
    );
    Assert.areEqual(rows, Limits.getDmlRows());
    Assert.isNull(FeaturedEpicService.read());
  }

  /**
   * The board's Remove (build 10 step 3): clears only the epic it was pressed on, so a tab left
   * open after another epic was featured cannot undo that choice.
   */
  @IsTest
  static void removingAnEpicClearsOnlyIfItIsStillTheFeaturedOne() {
    FeaturedEpicService.feature(idOf('EPIC-A'));
    FeaturedEpicService.feature(idOf('EPIC-B'));
    Integer rows = Limits.getDmlRows();

    FeaturedEpicService.Result stale = FeaturedEpicService.clear(
      idOf('EPIC-A')
    );

    Assert.isFalse(stale.saved);
    Assert.isFalse(stale.refused);
    Assert.areEqual(
      nameOf('EPIC-A') +
        ' is not featured on the public board, so nothing was changed. ' +
        nameOf('EPIC-B') +
        ' is.',
      stale.message
    );
    Assert.areEqual(rows, Limits.getDmlRows(), 'Nothing written.');
    Assert.areEqual(idOf('EPIC-B'), FeaturedEpicService.read());

    FeaturedEpicService.Result removed = FeaturedEpicService.clear(
      idOf('EPIC-B')
    );
    Assert.isTrue(removed.saved, removed.message);
    Assert.isNull(FeaturedEpicService.read());

    FeaturedEpicService.Result none = FeaturedEpicService.clear(idOf('EPIC-B'));
    Assert.isFalse(none.saved);
    Assert.areEqual(
      'No epic is featured, so nothing was changed.',
      none.message
    );
    Assert.isTrue(FeaturedEpicService.clear((Id) null).refused);
  }

  // ---------- refused, with a reason ----------

  @IsTest
  static void aNonEpicIsRefusedAndTheFeaturedEpicStays() {
    FeaturedEpicService.feature(idOf('EPIC-A'));
    Integer rows = Limits.getDmlRows();

    FeaturedEpicService.Result story = FeaturedEpicService.feature(
      idOf('STORY')
    );
    FeaturedEpicService.Result untyped = FeaturedEpicService.feature(
      idOf('UNTYPED')
    );

    Assert.isFalse(story.saved);
    Assert.isTrue(story.refused, 'A refusal the board shows as an error.');
    Assert.areEqual(
      nameOf('STORY') +
      ' is not an epic (its type is Story). Only an epic can be featured on the public board.',
      story.message
    );
    // Unspecified means "no mapping", not a type, so the reason does not call it one.
    Assert.areEqual(
      nameOf('UNTYPED') +
      ' is not an epic. Only an epic can be featured on the public board.',
      untyped.message
    );
    Assert.areEqual(rows, Limits.getDmlRows(), 'A refusal writes nothing.');
    Assert.areEqual(idOf('EPIC-A'), FeaturedEpicService.read());
  }

  /** The owner's answer to step 0's question 4: only an epic the public board can show. */
  @IsTest
  static void anEpicThePublicBoardCannotShowIsRefused() {
    FeaturedEpicService.Result notPublic = FeaturedEpicService.feature(
      idOf('PRIVATE-EPIC')
    );
    FeaturedEpicService.Result privateProject = FeaturedEpicService.feature(
      idOf('HIDDEN-PROJECT-EPIC')
    );
    FeaturedEpicService.Result noProject = FeaturedEpicService.feature(
      idOf('NO-PROJECT-EPIC')
    );

    Assert.isFalse(notPublic.saved);
    Assert.areEqual(
      nameOf('PRIVATE-EPIC') +
      ' is not public, so the public board cannot show it. Make it public, then feature it.',
      notPublic.message
    );
    Assert.isFalse(privateProject.saved);
    Assert.areEqual(
      nameOf('HIDDEN-PROJECT-EPIC') +
      '\'s project is not public, so the public board cannot show it. Make the project public, then feature it.',
      privateProject.message
    );
    Assert.isFalse(noProject.saved);
    Assert.areEqual(
      nameOf('NO-PROJECT-EPIC') +
      ' belongs to no project, and the public board shows only work under a public project.',
      noProject.message
    );
    Assert.isNull(FeaturedEpicService.storedId());
  }

  @IsTest
  static void nothingAndOtherKindsOfRecordAreRefused() {
    Id project = [SELECT Id FROM Project__c LIMIT 1].Id;

    FeaturedEpicService.Result none = FeaturedEpicService.feature(null);
    FeaturedEpicService.Result notAWorkItem = FeaturedEpicService.feature(
      project
    );

    Assert.isFalse(none.saved);
    Assert.areEqual(
      'No epic was supplied, so nothing was featured.',
      none.message
    );
    Assert.isFalse(notAWorkItem.saved);
    Assert.areEqual(
      'That is not a work item, so it cannot be featured.',
      notAWorkItem.message
    );
    Assert.isNull(FeaturedEpicService.storedId());
  }

  @IsTest
  static void aDeletedWorkItemIsRefused() {
    Id epic = idOf('EPIC-A');
    delete new Work_Item__c(Id = epic);

    FeaturedEpicService.Result result = FeaturedEpicService.feature(epic);

    Assert.isFalse(result.saved);
    Assert.areEqual(
      'That work item is not available to you. It may have been deleted.',
      result.message
    );
  }

  // ---------- read as none ----------

  @IsTest
  static void aDeletedEpicReadsAsNone() {
    Id epic = idOf('EPIC-A');
    FeaturedEpicService.feature(epic);

    delete new Work_Item__c(Id = epic);

    Assert.isNull(FeaturedEpicService.read());
    // Read as none, not cleared: the Id stays until the owner features another epic or clears it.
    Assert.areEqual(epic, FeaturedEpicService.storedId());
  }

  @IsTest
  static void anEpicThatIsNoLongerAnEpicReadsAsNone() {
    Id epic = idOf('EPIC-A');
    FeaturedEpicService.feature(epic);

    // What an inbound delivery carrying another issue type does to it.
    update new Work_Item__c(Id = epic, Type__c = 'Story');

    Assert.isNull(FeaturedEpicService.read());
  }

  @IsTest
  static void anEpicMadePrivateReadsAsNoneAndComesBackWhenPublicAgain() {
    Id epic = idOf('EPIC-A');
    FeaturedEpicService.feature(epic);

    update new Work_Item__c(Id = epic, Is_Public__c = false);
    Assert.isNull(FeaturedEpicService.read());

    update new Work_Item__c(Id = epic, Is_Public__c = true);
    Assert.areEqual(epic, FeaturedEpicService.read());
  }

  @IsTest
  static void anEpicWhoseProjectIsMadePrivateReadsAsNone() {
    Id epic = idOf('EPIC-A');
    FeaturedEpicService.feature(epic);

    Work_Item__c row = [SELECT Project__c FROM Work_Item__c WHERE Id = :epic];
    update new Project__c(Id = row.Project__c, Is_Public__c = false);

    Assert.isNull(FeaturedEpicService.read());
  }

  /** A value typed into the setting by hand is data like any other, and read defensively. */
  @IsTest
  static void aStoredValueThatIsNotAWorkItemIdReadsAsNone() {
    Featured_Epic__c setting = new Featured_Epic__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Epic_Id__c = 'not an id'
    );
    insert setting;
    Assert.isNull(FeaturedEpicService.storedId());
    Assert.isNull(FeaturedEpicService.read());

    setting.Epic_Id__c = [SELECT Id FROM Project__c LIMIT 1].Id;
    update setting;
    Assert.isNull(FeaturedEpicService.storedId());
    Assert.isNull(FeaturedEpicService.read());

    // And featuring over it writes the same row.
    Assert.isTrue(FeaturedEpicService.feature(idOf('EPIC-A')).saved);
    Assert.areEqual(1, [SELECT COUNT() FROM Featured_Epic__c]);
    Assert.areEqual(idOf('EPIC-A'), FeaturedEpicService.read());
  }

  // ---------- resolving among rows a board already loaded (step 2) ----------

  private static List<Work_Item__c> boardRows() {
    return [
      SELECT
        Id,
        Name,
        Type__c,
        Is_Public__c,
        Project__c,
        Project__r.Is_Public__c
      FROM Work_Item__c
    ];
  }

  @IsTest
  static void resolvingAmongLoadedRowsUsesTheSameRuleAndNoQuery() {
    Id epic = idOf('EPIC-A');
    FeaturedEpicService.feature(epic);
    List<Work_Item__c> rows = boardRows();

    Integer queries = Limits.getQueries();
    Id resolved = FeaturedEpicService.resolveAmong(rows);
    Assert.areEqual(
      queries,
      Limits.getQueries(),
      'The boards resolve with no query: the public board has one to spend, and it is spent.'
    );
    Assert.areEqual(epic, resolved);

    update new Work_Item__c(Id = epic, Is_Public__c = false);
    Assert.isNull(
      FeaturedEpicService.resolveAmong(boardRows()),
      'The rule that refuses a private epic reads one back as none.'
    );
  }

  @IsTest
  static void anEpicTheCallerDidNotLoadResolvesToNone() {
    FeaturedEpicService.feature(idOf('EPIC-A'));
    List<Work_Item__c> withoutIt = new List<Work_Item__c>();
    for (Work_Item__c row : boardRows()) {
      if (row.Id != idOf('EPIC-A')) {
        withoutIt.add(row);
      }
    }

    Assert.isNull(FeaturedEpicService.resolveAmong(withoutIt));
    Assert.isNull(FeaturedEpicService.resolveAmong(null));
  }

  @IsTest
  static void nothingStoredResolvesToNone() {
    Assert.isNull(FeaturedEpicService.resolveAmong(boardRows()));
  }

  // ---------- the guards: never a work item, never a push ----------

  /**
   * Featuring, replacing and clearing each write exactly one row: the setting's. A work item write
   * that changes nothing - which stages nothing and queues nothing, so the two guards below cannot
   * see it - is still a second row here. Proved by planting one.
   */
  @IsTest
  static void eachChangeWritesOneRowTheSettings() {
    Id epicA = idOf('EPIC-A');
    Id epicB = idOf('EPIC-B');
    Test.startTest();

    Integer rows = Limits.getDmlRows();
    Integer statements = Limits.getDmlStatements();
    FeaturedEpicService.feature(epicA);
    Assert.areEqual(
      1,
      Limits.getDmlRows() - rows,
      'Featuring writes one row, the setting\'s.'
    );
    Assert.areEqual(1, Limits.getDmlStatements() - statements);

    rows = Limits.getDmlRows();
    statements = Limits.getDmlStatements();
    FeaturedEpicService.feature(epicB);
    Assert.areEqual(
      1,
      Limits.getDmlRows() - rows,
      'Replacing writes one row, the setting\'s.'
    );
    Assert.areEqual(1, Limits.getDmlStatements() - statements);

    rows = Limits.getDmlRows();
    statements = Limits.getDmlStatements();
    FeaturedEpicService.clear();
    Assert.areEqual(
      1,
      Limits.getDmlRows() - rows,
      'Clearing writes one row, the setting\'s.'
    );
    Assert.areEqual(1, Limits.getDmlStatements() - statements);

    Test.stopTest();
  }

  /** No push job is queued: nothing reaches WorkItemTrigger, so nothing reaches Jira or Asana. */
  @IsTest
  static void noChangeQueuesAPush() {
    Id epicA = idOf('EPIC-A');
    Id epicB = idOf('EPIC-B');
    Test.startTest();

    Integer jobs = Limits.getQueueableJobs();
    FeaturedEpicService.feature(epicA);
    FeaturedEpicService.feature(epicB);
    FeaturedEpicService.clear();
    Assert.areEqual(
      jobs,
      Limits.getQueueableJobs(),
      'Featuring an epic queued a job. A push to Jira or Asana must never follow from it.'
    );

    Test.stopTest();
  }

  /** Every work item reads afterwards exactly as it did before: nothing staged, nothing Pending. */
  @IsTest
  static void noChangeTouchesAWorkItem() {
    Map<Id, Work_Item__c> before = snapshot();

    FeaturedEpicService.feature(idOf('EPIC-A'));
    FeaturedEpicService.feature(idOf('EPIC-B'));
    FeaturedEpicService.clear();

    Map<Id, Work_Item__c> after = snapshot();
    for (Id itemId : before.keySet()) {
      Assert.isNull(
        after.get(itemId).Pending_Push_Fields__c,
        'A field was staged for a push: ' + after.get(itemId)
      );
      Assert.areEqual(
        before.get(itemId),
        after.get(itemId),
        'A work item changed when an epic was featured.'
      );
    }
  }
}
