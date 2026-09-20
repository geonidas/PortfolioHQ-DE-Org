/**
 * The guest read path.
 *
 * The assertions fall into two kinds. Some check behaviour - what the query returns, what the DTO
 * carries. Others check the shape of the grant itself, against permission set metadata, because a
 * fresh scratch org may have no site and therefore no guest user to run as. Build 03 set that
 * precedent in GuestAccessTest and it holds here: the metadata assertions are deterministic
 * everywhere, and the runtime ones run whenever a guest exists.
 */
@IsTest
private class PublicBoardControllerTest {
  private static Project__c project(Boolean isPublic, String shortName) {
    Project__c p = TestDataFactory.createProjects(1, false)[0];
    p.Is_Public__c = isPublic;
    p.Short_Name__c = shortName;
    insert p;
    return p;
  }

  private static Work_Item__c item(
    Id projectId,
    Boolean isPublic,
    String status
  ) {
    Work_Item__c w = TestDataFactory.createWorkItems(1, projectId, false)[0];
    w.Is_Public__c = isPublic;
    w.Status__c = status;
    w.Sync_Status__c = 'Pending';
    insert w;
    return w;
  }

  /** A work item with its type and parent under the caller's control. */
  private static Work_Item__c item(
    Id projectId,
    Boolean isPublic,
    String status,
    String type,
    Id parentId
  ) {
    Work_Item__c w = TestDataFactory.createWorkItems(1, projectId, false)[0];
    w.Is_Public__c = isPublic;
    w.Status__c = status;
    w.Sync_Status__c = 'Pending';
    w.Type__c = type;
    w.Parent_Work_Item__c = parentId;
    insert w;
    return w;
  }

  private static Work_Item__c epic(
    Id projectId,
    Boolean isPublic,
    String status
  ) {
    return item(projectId, isPublic, status, 'Epic', null);
  }

  private static Map<String, PublicBoardController.PublicEpic> epicsByTitle(
    PublicBoardController.PublicBoardData board
  ) {
    Map<String, PublicBoardController.PublicEpic> byTitle = new Map<String, PublicBoardController.PublicEpic>();
    for (PublicBoardController.PublicEpic e : board.epics) {
      byTitle.put(e.title, e);
    }
    return byTitle;
  }

  /** A public work item from a system that has no epics. */
  private static Work_Item__c flatItem(
    Id projectId,
    String status,
    String title
  ) {
    Work_Item__c w = TestDataFactory.createWorkItems(1, projectId, false)[0];
    w.Is_Public__c = true;
    w.Status__c = status;
    w.Sync_Status__c = 'Pending';
    w.Type__c = WorkItemType.TASK;
    w.Title__c = title;
    w.External_System__c = ExternalSystem.ASANA;
    w.External_Id__c = 'asana:' + Math.abs(Crypto.getRandomLong());
    w.External_Key__c = null;
    insert w;
    return w;
  }

  private static PublicBoardController.PublicCard cardTitled(
    PublicBoardController.PublicBoardData board,
    String title
  ) {
    for (PublicBoardController.PublicCard card : board.items) {
      if (card.title == title) {
        return card;
      }
    }
    return null;
  }

  private static Set<String> numbersFrom(
    PublicBoardController.PublicBoardData board
  ) {
    Set<String> numbers = new Set<String>();
    for (PublicBoardController.PublicCard card : board.items) {
      numbers.add(card.recordNumber);
    }
    return numbers;
  }

  // ---------- epic resolution and the two views (build 06) ----------

  @IsTest
  static void resolvesAnEpicAtOneHopAndAtTwo() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c theEpic = epic(open.Id, true, 'In Progress');
    Work_Item__c story = item(open.Id, true, 'To Do', 'Story', theEpic.Id);
    Work_Item__c subtask = item(open.Id, true, 'To Do', 'Task', story.Id);

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Set<String> shown = numbersFrom(board);
    Map<Id, Work_Item__c> named = new Map<Id, Work_Item__c>(
      [
        SELECT Name
        FROM Work_Item__c
        WHERE Id IN :new List<Id>{ story.Id, subtask.Id }
      ]
    );
    Assert.isTrue(
      shown.contains(named.get(story.Id).Name),
      'One hop up to the epic.'
    );
    Assert.isTrue(
      shown.contains(named.get(subtask.Id).Name),
      'Two hops up, through the story, to the same epic.'
    );
    // Both descendants count towards the epic, not just the direct child, so the number on
    // the card matches the number of cards the task view shows beneath it.
    Assert.areEqual(2, board.epics[0].totalChildren);
  }

  @IsTest
  static void aCycleInTheHierarchyTerminates() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c a = item(open.Id, true, 'To Do', 'Story', null);
    Work_Item__c b = item(open.Id, true, 'To Do', 'Story', a.Id);
    // Close the loop. Nothing in the schema prevents this.
    update new Work_Item__c(Id = a.Id, Parent_Work_Item__c = b.Id);

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    // Reaching this assertion at all is the test: the walk terminated rather than hanging.
    // A cycle has no epic ancestor, so both rows fall through to the orphan rule.
    Assert.areEqual(
      2,
      board.itemCount,
      'Both rows survive as unfinished orphans rather than hanging the request.'
    );
    Assert.isTrue(board.epics.isEmpty(), 'Neither is an epic.');
  }

  @IsTest
  static void aDoneOrphanIsHiddenButALiveOneIsNot() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c live = item(open.Id, true, 'In Progress', 'Story', null);
    Work_Item__c finished = item(open.Id, true, 'Done', 'Story', null);

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Set<String> shown = numbersFrom(board);
    Map<Id, Work_Item__c> named = new Map<Id, Work_Item__c>(
      [
        SELECT Name
        FROM Work_Item__c
        WHERE Id IN :new List<Id>{ live.Id, finished.Id }
      ]
    );
    Assert.isTrue(
      shown.contains(named.get(live.Id).Name),
      'Real unparented work stays visible.'
    );
    // Otherwise finished orphans accumulate into the unbounded Done column the two-view
    // design exists to avoid.
    Assert.isFalse(
      shown.contains(named.get(finished.Id).Name),
      'A finished orphan does not.'
    );
  }

  @IsTest
  static void aTaskUnderALiveEpicShowsEvenWhenItIsDone() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c live = epic(open.Id, true, 'In Progress');
    Work_Item__c finishedEpic = epic(open.Id, true, 'Done');
    Work_Item__c underLive = item(open.Id, true, 'Done', 'Story', live.Id);
    Work_Item__c underFinished = item(
      open.Id,
      true,
      'In Progress',
      'Story',
      finishedEpic.Id
    );

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Set<String> shown = numbersFrom(board);
    Map<Id, Work_Item__c> named = new Map<Id, Work_Item__c>(
      [
        SELECT Name
        FROM Work_Item__c
        WHERE Id IN :new List<Id>{ underLive.Id, underFinished.Id }
      ]
    );
    Assert.isTrue(
      shown.contains(named.get(underLive.Id).Name),
      'A finished task stays visible while its epic is in flight.'
    );
    Assert.isFalse(
      shown.contains(named.get(underFinished.Id).Name),
      'Work under a completed epic leaves the task view whatever its own status.'
    );
  }

  @IsTest
  static void theEpicDtoCarriesExactlyFourKeys() {
    Project__c open = project(true, 'OPEN');
    epic(open.Id, true, 'In Progress');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Map<String, Object> onTheWire = (Map<String, Object>) JSON.deserializeUntyped(
      JSON.serialize(board.epics[0])
    );
    // An exact set, exactly as PublicCard is asserted. Both views ship on every call
    // whichever one is on screen, so the epic payload is held to the same standard.
    Set<String> expected = new Set<String>{
      'title',
      'status',
      'totalChildren',
      'completedChildren'
    };
    Assert.areEqual(
      expected,
      onTheWire.keySet(),
      'The epic payload changed shape.'
    );
  }

  @IsTest
  static void aNonPublicEpicIsAbsentFromTheEpicView() {
    Project__c open = project(true, 'OPEN');
    Project__c shut = project(false, 'SHUT');
    epic(open.Id, true, 'In Progress');
    epic(open.Id, false, 'In Progress');
    epic(shut.Id, true, 'In Progress');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Assert.areEqual(
      1,
      board.epics.size(),
      'Only the doubly public epic should come back - a private epic and a public epic under a private project must not.'
    );
  }

  @IsTest
  static void theEpicViewCapsCompletedEpicsAtThree() {
    Project__c open = project(true, 'OPEN');
    epic(open.Id, true, 'In Progress');
    for (Integer i = 0; i < 5; i++) {
      epic(open.Id, true, 'Done');
    }

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Integer done = 0;
    Integer active = 0;
    for (PublicBoardController.PublicEpic e : board.epics) {
      if (e.status == 'Done') {
        done++;
      } else {
        active++;
      }
    }
    Assert.areEqual(1, active, 'Every active epic is shown.');
    // An unbounded list of finished epics is the same failure as an unbounded Done column.
    Assert.areEqual(3, done, 'Completed epics are capped at three.');
  }

  @IsTest
  static void childCountsAreCorrectIncludingAnEpicWithNone() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c busy = epic(open.Id, true, 'In Progress');
    Work_Item__c bare = epic(open.Id, true, 'In Progress');
    update new Work_Item__c(Id = busy.Id, Title__c = 'Busy epic');
    update new Work_Item__c(Id = bare.Id, Title__c = 'Bare epic');
    item(open.Id, true, 'Done', 'Story', busy.Id);
    item(open.Id, true, 'Done', 'Story', busy.Id);
    item(open.Id, true, 'To Do', 'Story', busy.Id);

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Map<String, PublicBoardController.PublicEpic> byTitle = epicsByTitle(board);
    Assert.areEqual(3, byTitle.get('Busy epic').totalChildren);
    Assert.areEqual(2, byTitle.get('Busy epic').completedChildren);
    // Zero rather than null, so the card reads as empty rather than as broken.
    Assert.areEqual(0, byTitle.get('Bare epic').totalChildren);
    Assert.areEqual(0, byTitle.get('Bare epic').completedChildren);
  }

  @IsTest
  static void aWithheldEpicBreaksTheChainAndItsChildBecomesAnOrphan() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c hidden = epic(open.Id, false, 'In Progress');
    Work_Item__c child = item(open.Id, true, 'Done', 'Story', hidden.Id);

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    // The walk only sees public rows, so the chain stops at the withheld epic and the child
    // reads as an orphan - which, being Done, means it is hidden. Documented rather than
    // incidental: an epic's counts can legitimately disagree with Jira.
    Assert.areEqual(
      0,
      board.itemCount,
      'A Done child under a withheld epic falls through to the orphan rule.'
    );
    Assert.isTrue(
      board.epics.isEmpty(),
      'And the withheld epic is not published.'
    );
  }

  @IsTest
  static void theQueryCountDoesNotScaleWithEpicCount() {
    Project__c open = project(true, 'OPEN');
    for (Integer i = 0; i < 12; i++) {
      Work_Item__c e = epic(open.Id, true, 'In Progress');
      item(open.Id, true, 'To Do', 'Story', e.Id);
    }

    Test.startTest();
    Integer before = Limits.getQueries();
    PublicBoardController.getPublicBoardData();
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    // One query, whatever the shape of the data. Counts and ancestry are computed in memory
    // from the rows that query already returned; a per-epic query would put the guest page
    // one busy project away from the governor limit.
    Assert.areEqual(
      1,
      used,
      'The guest read path must issue exactly one query regardless of epic count.'
    );
  }

  // ---------- the filter ----------

  @IsTest
  static void bothPublicFlagsAreRequired() {
    Project__c open = project(true, 'OPEN');
    Project__c shut = project(false, 'SHUT');
    Work_Item__c visible = item(open.Id, true, 'To Do');
    Work_Item__c privateItem = item(open.Id, false, 'To Do');
    Work_Item__c underPrivateProject = item(shut.Id, true, 'To Do');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Set<String> shown = numbersFrom(board);
    Assert.areEqual(
      1,
      board.itemCount,
      'Only the doubly public record should come back.'
    );
    Assert.isTrue(
      shown.contains(
        [SELECT Name FROM Work_Item__c WHERE Id = :visible.Id].Name
      ),
      'Public under public.'
    );
    Assert.isFalse(
      shown.contains(
        [SELECT Name FROM Work_Item__c WHERE Id = :privateItem.Id].Name
      ),
      'A private work item must never appear.'
    );
    // The flag the sharing rule cannot enforce - only the query does.
    Assert.isFalse(
      shown.contains(
        [SELECT Name FROM Work_Item__c WHERE Id = :underPrivateProject.Id].Name
      ),
      'A public work item under a private project must never appear.'
    );
  }

  @IsTest
  static void aNonPublicRecordIsAbsentByIdentity() {
    Project__c open = project(true, 'OPEN');
    item(open.Id, true, 'To Do');
    Work_Item__c hidden = item(open.Id, false, 'Done');
    String hiddenNumber = [SELECT Name FROM Work_Item__c WHERE Id = :hidden.Id]
    .Name;

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    for (PublicBoardController.PublicCard card : board.items) {
      Assert.areNotEqual(
        hiddenNumber,
        card.recordNumber,
        'The withheld record leaked into the payload.'
      );
    }
  }

  @IsTest
  static void nothingPublicIsAnEmptyBoardNotAnError() {
    project(false, 'SHUT');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Assert.areEqual(0, board.itemCount, 'No public data is a valid answer.');
    Assert.isNull(board.lastSyncedAt, 'And carries no freshness.');
  }

  // ---------- the payload ----------

  @IsTest
  static void theDtoCarriesExactlyTheAgreedFieldsAndNoOthers() {
    Project__c open = project(true, 'OPEN');
    item(open.Id, true, 'In Progress');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Map<String, Object> onTheWire = (Map<String, Object>) JSON.deserializeUntyped(
      JSON.serialize(board.items[0])
    );
    // An exact set, not a blocklist. Adding a field to the DTO fails this test, which forces
    // publishing something new to a guest to be a deliberate act rather than a side effect.
    Set<String> expected = new Set<String>{
      'recordNumber',
      'title',
      'externalKey',
      'status',
      'type',
      'projectLabel',
      'parentNumber',
      'syncStatus',
      'lastSyncedAt',
      // Build 07 step 9. A boolean, not the source system's name: the client needs to know
      // what the epic toggle does to this card, and does not need to know which vendor the
      // work came from. Adding it here was the deliberate act - this assertion failed first.
      'condensesIntoEpic'
    };
    Assert.areEqual(
      expected,
      onTheWire.keySet(),
      'The guest payload changed shape.'
    );
  }

  @IsTest
  static void theDtoCarriesNoSalesforceIdAndNoExcludedField() {
    Project__c open = project(true, 'OPEN');
    item(open.Id, true, 'In Progress');

    Test.startTest();
    String wire = JSON.serialize(PublicBoardController.getPublicBoardData());
    Test.stopTest();

    for (
      String banned : new List<String>{
        'Description__c',
        'Assignee__c',
        'External_URL__c',
        'Is_Public__c',
        // Build 07 step 7. Source_Type__c holds the type string exactly as a vendor sent it,
        // which on the Asana board means whatever somebody typed into a custom field. It is on
        // no DTO, and the exact key-set assertions above are what keep it that way; this is
        // the belt to their braces.
        'Source_Type__c',
        'sourceType'
      }
    ) {
      Assert.isFalse(
        wire.contains(banned),
        banned + ' must never reach an unauthenticated browser.'
      );
    }
    // Ids are addressable handles; auto numbers are not. Nothing a visitor receives should be
    // usable to attempt direct record access.
    Assert.isFalse(
      wire.contains('"Id"'),
      'No Salesforce id should be serialised.'
    );
    Assert.isFalse(
      wire.contains(String.valueOf(UserInfo.getUserId()).substring(0, 15)),
      'No user id either.'
    );
  }

  @IsTest
  static void anUnmappedTypeIsFlattenedSoTheClientNeedNotKnowTheSentinel() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c w = item(open.Id, true, 'To Do');
    update new Work_Item__c(Id = w.Id, Type__c = 'Unspecified');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Assert.isNull(
      board.items[0].type,
      'Unspecified should arrive as null, not as a magic string.'
    );
  }

  @IsTest
  static void projectLabelUsesShortNameAndNeverFallsBackToName() {
    Project__c open = project(true, null); // no short name
    item(open.Id, true, 'To Do');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    // Falling back to Project__c.Name would publish the internal project name.
    Assert.isNull(
      board.items[0].projectLabel,
      'A blank short name must render no label, not the Name.'
    );
    Assert.isFalse(
      JSON.serialize(board).contains(open.Name),
      'The internal project name must not be published.'
    );
  }

  @IsTest
  static void parentLinkageResolvesOnlyToAPublicParent() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c publicParent = item(open.Id, true, 'To Do');
    Work_Item__c hiddenParent = item(open.Id, false, 'To Do');
    Work_Item__c childOfPublic = item(open.Id, true, 'To Do');
    Work_Item__c childOfHidden = item(open.Id, true, 'To Do');
    update new List<Work_Item__c>{
      new Work_Item__c(
        Id = childOfPublic.Id,
        Parent_Work_Item__c = publicParent.Id
      ),
      new Work_Item__c(
        Id = childOfHidden.Id,
        Parent_Work_Item__c = hiddenParent.Id
      )
    };
    Map<Id, Work_Item__c> named = new Map<Id, Work_Item__c>(
      [SELECT Id, Name FROM Work_Item__c]
    );

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Map<String, String> parentByNumber = new Map<String, String>();
    for (PublicBoardController.PublicCard card : board.items) {
      parentByNumber.put(card.recordNumber, card.parentNumber);
    }
    Assert.areEqual(
      named.get(publicParent.Id).Name,
      parentByNumber.get(named.get(childOfPublic.Id).Name),
      'A public parent should be linked.'
    );
    // Naming a parent the visitor cannot see would reveal it exists.
    Assert.isNull(
      parentByNumber.get(named.get(childOfHidden.Id).Name),
      'A withheld parent must not be named, even indirectly.'
    );
  }

  // ---------- shape of the entry point ----------

  @IsTest
  static void theEntryPointTakesNoArgument() {
    Project__c open = project(true, 'OPEN');
    item(open.Id, true, 'To Do');

    Test.startTest();
    // The assertion here is the compiler's. This call passes nothing, so adding a parameter
    // that a client could use to widen scope breaks this test at compile time.
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Assert.areEqual(1, board.itemCount, 'And it still returns the public set.');
  }

  // ---------- limits ----------

  @IsTest
  static void twoHundredPublicRecordsCostOneQuery() {
    Project__c open = project(true, 'OPEN');
    List<Work_Item__c> many = TestDataFactory.createWorkItems(
      200,
      open.Id,
      false
    );
    for (Work_Item__c w : many) {
      w.Is_Public__c = true;
      w.Status__c = 'In Progress';
      w.Sync_Status__c = 'Pending';
    }
    insert many;

    Test.startTest();
    Integer before = Limits.getQueries();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    Assert.areEqual(200, board.itemCount, 'All public records should return.');
    // The parent map is built in memory from the same rows, so volume costs nothing extra.
    Assert.areEqual(
      1,
      used,
      'Query count must not scale with the number of records.'
    );
  }

  // ---------- the grant itself ----------

  @IsTest
  static void theGuestGrantReachesOnlyThePublicController() {
    List<SetupEntityAccess> access = [
      SELECT SetupEntityId
      FROM SetupEntityAccess
      WHERE
        ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Portfolio_HQ_Guest'
        )
        AND SetupEntityType = 'ApexClass'
    ];
    Set<Id> granted = new Set<Id>();
    for (SetupEntityAccess entry : access) {
      granted.add(entry.SetupEntityId);
    }
    List<String> names = new List<String>();
    for (ApexClass cls : [SELECT Name FROM ApexClass WHERE Id IN :granted]) {
      names.add(cls.Name);
    }

    Assert.areEqual(1, names.size(), 'Exactly one class, got: ' + names);
    Assert.areEqual(
      'PublicBoardController',
      names[0],
      'And it must be the read-only one.'
    );
    // Class access is per class, not per method: reaching WorkItemBoardController at all would
    // expose changeStatus, whatever the page renders.
    Assert.isFalse(
      names.contains('WorkItemBoardController'),
      'The write controller must be unreachable.'
    );
  }

  @IsTest
  static void theGuestGrantAllowsNoWriteAndNoRestrictedObject() {
    List<ObjectPermissions> grants = [
      SELECT
        SobjectType,
        PermissionsCreate,
        PermissionsEdit,
        PermissionsDelete,
        PermissionsViewAllRecords,
        PermissionsModifyAllRecords
      FROM ObjectPermissions
      WHERE
        ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Portfolio_HQ_Guest'
        )
    ];
    Assert.isFalse(grants.isEmpty(), 'The guest set should grant something.');
    Set<String> allowed = new Set<String>{ 'Work_Item__c', 'Project__c' };
    Set<String> forbidden = new Set<String>{
      'Integration_Log__c',
      'Webhook_Event__c',
      'Integration_Secret__mdt',
      'Account',
      'Contact',
      'Opportunity',
      'User'
    };
    for (ObjectPermissions grant : grants) {
      Assert.isTrue(
        allowed.contains(grant.SobjectType),
        'Unexpected object: ' + grant.SobjectType
      );
      Assert.isFalse(
        forbidden.contains(grant.SobjectType),
        'Forbidden object: ' + grant.SobjectType
      );
      Assert.isFalse(
        grant.PermissionsCreate,
        'No create on ' + grant.SobjectType
      );
      Assert.isFalse(grant.PermissionsEdit, 'No edit on ' + grant.SobjectType);
      Assert.isFalse(
        grant.PermissionsDelete,
        'No delete on ' + grant.SobjectType
      );
      Assert.isFalse(
        grant.PermissionsViewAllRecords,
        'No view all on ' + grant.SobjectType
      );
      Assert.isFalse(
        grant.PermissionsModifyAllRecords,
        'No modify all on ' + grant.SobjectType
      );
    }
  }

  @IsTest
  static void theGuestGrantIsReadOnlyAtFieldLevelToo() {
    List<FieldPermissions> fields = [
      SELECT SobjectType, Field, PermissionsEdit
      FROM FieldPermissions
      WHERE
        ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Portfolio_HQ_Guest'
        )
    ];
    Assert.isFalse(
      fields.isEmpty(),
      'The DTO needs field access to be readable at all.'
    );
    for (FieldPermissions field : fields) {
      Assert.isFalse(
        field.PermissionsEdit,
        'No editable field for a guest: ' + field.Field
      );
    }
  }

  // ---------- the guest user, when one exists ----------

  @IsTest
  static void theGuestCannotWriteAWorkItem() {
    List<User> guests = [
      SELECT Id
      FROM User
      WHERE UserType = 'Guest' AND IsActive = TRUE
      LIMIT 1
    ];
    if (guests.isEmpty()) {
      // No site, no guest user. The grant assertions above still stand.
      return;
    }
    Project__c open = project(true, 'OPEN');
    Work_Item__c target = item(open.Id, true, 'To Do');

    Boolean refused = false;
    System.runAs(guests[0]) {
      try {
        // USER_MODE is the point. Plain DML runs in system mode and would succeed here,
        // proving nothing about what the guest is actually allowed to do.
        Database.update(
          new Work_Item__c(Id = target.Id, Status__c = 'Done'),
          AccessLevel.USER_MODE
        );
      } catch (Exception e) {
        refused = true;
      }
    }
    Assert.isTrue(
      refused,
      'A guest must not be able to change a work item status.'
    );
    Assert.areEqual(
      'To Do',
      [SELECT Status__c FROM Work_Item__c WHERE Id = :target.Id].Status__c,
      'And the record must be unchanged.'
    );
  }

  @IsTest
  static void theGuestCannotReadTheIntegrationObjects() {
    List<User> guests = [
      SELECT Id
      FROM User
      WHERE UserType = 'Guest' AND IsActive = TRUE
      LIMIT 1
    ];
    if (guests.isEmpty()) {
      return;
    }
    Boolean logRefused = false;
    Boolean secretRefused = false;
    System.runAs(guests[0]) {
      try {
        Integer ignored = [
          SELECT COUNT()
          FROM Integration_Log__c
          WITH USER_MODE
        ];
      } catch (Exception e) {
        logRefused = true;
      }
      try {
        Integer ignored = [
          SELECT COUNT()
          FROM Integration_Secret__mdt
          WITH USER_MODE
        ];
      } catch (Exception e) {
        secretRefused = true;
      }
    }
    Assert.isTrue(logRefused, 'Integration_Log__c must stay out of reach.');
    Assert.isTrue(secretRefused, 'The signing secret must stay out of reach.');
  }

  // ---------- a second source on one board (build 07 step 9) ----------

  @IsTest
  static void aCardSaysWhetherTheEpicToggleRollsItUp() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c epic = epic(open.Id, true, 'In Progress');
    item(open.Id, true, 'In Progress', 'Story', epic.Id);
    flatItem(open.Id, 'In Progress', 'A course');

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    PublicBoardController.PublicCard flat = cardTitled(board, 'A course');
    Assert.isNotNull(flat, 'The flat item is on the task view.');
    Assert.isFalse(
      flat.condensesIntoEpic,
      'It has no epic to roll up into, so the toggle leaves it alone.'
    );

    Boolean sawCondensing = false;
    for (PublicBoardController.PublicCard card : board.items) {
      if (card.condensesIntoEpic) {
        sawCondensing = true;
      }
    }
    Assert.isTrue(
      sawCondensing,
      'And work from a system that does use epics says so - or the assertion above would ' +
      'pass because nothing ever condenses.'
    );
  }

  @IsTest
  static void aFinishedFlatItemStaysOnTheBoard() {
    // The orphan rule hides FINISHED unparented work, because it ought to sit under an epic.
    // Work from a system with no epics has nothing to sit under, and hiding it the moment it
    // is finished would make completing something look like deleting it.
    Project__c open = project(true, 'OPEN');
    flatItem(open.Id, 'Done', 'A finished course');
    item(open.Id, true, 'Done', 'Story', null);

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Assert.isNotNull(
      cardTitled(board, 'A finished course'),
      'The flat item is still shown.'
    );
    Assert.areEqual(
      1,
      board.items.size(),
      'And the finished orphan from a system that DOES use epics is still hidden, so this ' +
      'is a per-source rule rather than the orphan rule quietly being switched off.'
    );
  }

  @IsTest
  static void aFlatItemIsNeverCountedTowardsAnEpic() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c parentEpic = epic(open.Id, true, 'In Progress');
    item(open.Id, true, 'In Progress', 'Story', parentEpic.Id);
    // Deliberately parented to the epic, which a flat source would never do - but nothing in
    // the schema prevents it, and the count must not move if somebody sets it by hand.
    Work_Item__c flat = TestDataFactory.createWorkItems(1, open.Id, false)[0];
    flat.Is_Public__c = true;
    flat.Status__c = 'In Progress';
    flat.Sync_Status__c = 'Pending';
    flat.Type__c = WorkItemType.TASK;
    flat.Parent_Work_Item__c = parentEpic.Id;
    flat.External_System__c = ExternalSystem.ASANA;
    flat.External_Id__c = 'asana:' + Math.abs(Crypto.getRandomLong());
    flat.External_Key__c = null;
    insert flat;

    Test.startTest();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Test.stopTest();

    Assert.areEqual(
      1,
      board.epics[0].totalChildren,
      'Only the card that condenses counts towards the epic. A flat card is shown as itself ' +
      'in both views, so counting it too would show it twice.'
    );
  }

  @IsTest
  static void oneQueryWhateverTheMixOfSources() {
    Project__c open = project(true, 'OPEN');
    Work_Item__c parentEpic = epic(open.Id, true, 'In Progress');
    for (Integer i = 0; i < 4; i++) {
      item(open.Id, true, 'In Progress', 'Story', parentEpic.Id);
      flatItem(open.Id, 'To Do', 'Flat ' + i);
    }

    Test.startTest();
    Integer before = Limits.getQueries();
    PublicBoardController.PublicBoardData board = PublicBoardController.getPublicBoardData();
    Integer after = Limits.getQueries();
    Test.stopTest();

    Assert.areEqual(
      1,
      after - before,
      'One SOQL query whatever the data shape. Ancestry and counts are computed in memory, ' +
        'because a per-epic query would put the guest page one busy project away from the ' +
        'governor limit.'
    );
    Assert.areEqual(8, board.items.size(), 'And every public card is there.');
  }
}
