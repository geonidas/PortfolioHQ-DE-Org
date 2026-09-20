/**
 * Processor behaviour: ordering, idempotency, loop prevention, project linkage and bulk.
 *
 * Payloads are Jira-shaped because JiraAdapter is the only adapter, but the class under test
 * never sees them: it hands the raw body to the adapter named by Source_System__c and applies
 * the InboundChange that comes back. Jira payload parsing itself is covered in JiraAdapterTest.
 *
 * Events are inserted BEFORE Test.startTest so their platform events are delivered at stopTest,
 * by which point process() has already run and moved the rows off Pending - so the subscriber
 * finds nothing and cannot double-process. Tests that want the real event path say so.
 */
@IsTest
private class WorkItemInboundProcessorTest {
  private static Work_Item__c seedItem(
    String externalId,
    String status,
    Datetime remoteUpdated
  ) {
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.External_Id__c = externalId;
    item.Status__c = status;
    item.Sync_Status__c = 'Pending';
    item.Remote_Last_Modified__c = remoteUpdated;
    insert item;
    return item;
  }

  private static List<Webhook_Event__c> deliver(List<String> payloads) {
    List<Webhook_Event__c> events = new List<Webhook_Event__c>();
    for (String payload : payloads) {
      events.add(JiraWebhookPayloadFactory.delivery(payload));
    }
    insert events;
    return [
      SELECT
        Id,
        Source_System__c,
        Raw_Payload__c,
        Processing_Status__c,
        Signature_Valid__c
      FROM Webhook_Event__c
    ];
  }

  // ---------- type and parent (build 06) ----------

  @IsTest
  static void storesTheIssueTypeFromThePayload() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10050', 'To Do', was);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10050',
          'DOPP-50',
          'In Progress',
          was.addMinutes(30),
          null,
          'Epic',
          null
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      'Epic',
      [SELECT Type__c FROM Work_Item__c WHERE Id = :item.Id].Type__c,
      'fields.issuetype.name should map through to Type__c.'
    );
  }

  @IsTest
  static void anUnrecognisedIssueTypeLandsOnUnspecified() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10051', 'To Do', was);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10051',
          'DOPP-51',
          'In Progress',
          was.addMinutes(30),
          null,
          'Incident Postmortem',
          null
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    // Type__c is a restricted picklist, so a custom Jira issue type has to land somewhere.
    // Failing the delivery over a labelling gap would throw away the status change with it.
    Assert.areEqual(
      'Unspecified',
      [SELECT Type__c FROM Work_Item__c WHERE Id = :item.Id].Type__c,
      'An unmapped issue type should land on the catch-all.'
    );
    Assert.areEqual(
      'In Progress',
      [SELECT Status__c FROM Work_Item__c WHERE Id = :item.Id].Status__c,
      'And the status change should still have been applied.'
    );
  }

  @IsTest
  static void aPayloadWithNoTypeOrParentLeavesBothAlone() {
    Datetime was = System.now().addHours(-1);
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c parent = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    parent.External_Id__c = 'jira:10052';
    parent.Status__c = 'To Do';
    parent.Sync_Status__c = 'Pending';
    insert parent;

    Work_Item__c child = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    child.External_Id__c = 'jira:10053';
    child.Status__c = 'To Do';
    child.Sync_Status__c = 'Pending';
    child.Remote_Last_Modified__c = was;
    child.Type__c = 'Bug';
    child.Parent_Work_Item__c = parent.Id;
    insert child;

    // A real status transition carries neither issuetype nor parent.
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10053',
          'DOPP-53',
          'Done',
          was.addMinutes(30),
          null,
          null,
          null
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c after = [
      SELECT Status__c, Type__c, Parent_Work_Item__c
      FROM Work_Item__c
      WHERE Id = :child.Id
    ];
    Assert.areEqual('Done', after.Status__c, 'The status should have moved.');
    // Writing a null through would blank known data on every status-only delivery, which is
    // most of them.
    Assert.areEqual('Bug', after.Type__c, 'Type__c must survive untouched.');
    Assert.areEqual(
      parent.Id,
      after.Parent_Work_Item__c,
      'Parent_Work_Item__c must survive untouched.'
    );
  }

  @IsTest
  static void resolvesAParentDeliveredInTheSameBatch() {
    Datetime was = System.now().addHours(-1);
    // Child first, so the batch proves ordering does not matter.
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10061',
          'DOPP-61',
          'To Do',
          was,
          'The child',
          'Story',
          '10060'
        ),
        JiraWebhookPayloadFactory.issueUpdated(
          '10060',
          'DOPP-60',
          'In Progress',
          was,
          'The parent',
          'Epic',
          null
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c parent = [
      SELECT Id
      FROM Work_Item__c
      WHERE External_Id__c = 'jira:10060'
    ];
    Work_Item__c child = [
      SELECT Parent_Work_Item__c
      FROM Work_Item__c
      WHERE External_Id__c = 'jira:10061'
    ];
    Assert.areEqual(
      parent.Id,
      child.Parent_Work_Item__c,
      'The second pass should link a parent that arrived in the same batch.'
    );
  }

  @IsTest
  static void anUnresolvableParentIsLoggedAndTheDeliveryStillSucceeds() {
    Datetime was = System.now().addHours(-1);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10070',
          'DOPP-70',
          'In Progress',
          was,
          'An orphaned child',
          'Story',
          '99999'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c child = [
      SELECT Id, Status__c, Parent_Work_Item__c
      FROM Work_Item__c
      WHERE External_Id__c = 'jira:10070'
    ];
    // No stub. The reference is a data gap to surface, not a record to invent.
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Work_Item__c],
      'No stub parent should have been created.'
    );
    Assert.isNull(
      child.Parent_Work_Item__c,
      'An unresolvable parent leaves the lookup null.'
    );
    Assert.areEqual(
      'In Progress',
      child.Status__c,
      'And the status change still lands - a data gap is not a reason to drop it.'
    );
    Assert.areEqual(
      'Processed',
      [
        SELECT Processing_Status__c
        FROM Webhook_Event__c
        WHERE Id = :events[0].Id
      ]
      .Processing_Status__c,
      'The delivery itself succeeded.'
    );

    List<Integration_Log__c> logs = [
      SELECT Direction__c, Is_Success__c, Error_Message__c
      FROM Integration_Log__c
    ];
    Assert.areEqual(1, logs.size(), 'The gap should be reported exactly once.');
    Assert.areEqual('Inbound', logs[0].Direction__c);
    Assert.isFalse(logs[0].Is_Success__c);
    Assert.isTrue(
      logs[0].Error_Message__c.contains('jira:99999'),
      'The log names the unresolved parent.'
    );
    Assert.isTrue(
      logs[0].Error_Message__c.contains('jira:10070'),
      'And the child that referenced it.'
    );
  }

  @IsTest
  static void aPayloadNamingItselfAsItsOwnParentIsRefused() {
    Datetime was = System.now().addHours(-1);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10080',
          'DOPP-80',
          'To Do',
          was,
          'A self-referencing issue',
          'Story',
          '10080'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    // A cycle of length one is still a cycle for anything walking ancestors.
    Assert.isNull(
      [
        SELECT Parent_Work_Item__c
        FROM Work_Item__c
        WHERE External_Id__c = 'jira:10080'
      ]
      .Parent_Work_Item__c,
      'A record must not be made its own parent.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Integration_Log__c],
      'And the refusal is reported.'
    );
  }

  @IsTest
  static void anUnresolvedOwnerIsReportedRatherThanPassedOverInSilence() {
    Datetime was = System.now().addHours(-1);
    // Force the "no admin resolved" branch without depending on the org having no admin.
    WorkItemInboundProcessor.integrationOwnerResolved = true;
    WorkItemInboundProcessor.integrationOwner = null;

    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10090',
          'DOPP-90',
          'To Do',
          was,
          'Created with nobody to own it',
          'Story',
          null
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    // Public, synced and invisible with nothing reporting it is the failure most likely to
    // waste an hour at launch, so it gets a row of its own.
    List<Integration_Log__c> logs = [
      SELECT Error_Message__c, Direction__c
      FROM Integration_Log__c
    ];
    Assert.areEqual(1, logs.size(), 'The ownership gap should be reported.');
    Assert.areEqual('Inbound', logs[0].Direction__c);
    Assert.isTrue(
      logs[0].Error_Message__c.contains('Automated Process'),
      'The log should say why the record will not be guest-visible.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Work_Item__c],
      'The record still syncs - ownership is not worth failing a delivery over.'
    );
  }

  // ---------- project linkage (refactor after build 06) ----------

  @IsTest
  static void aNewIssueIsLinkedToTheProjectItsKeyNames() {
    // TestDataFactory projects carry External_Project_Key__c = DOPP and External_System__c = Jira.
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10600',
          'DOPP-600',
          'To Do',
          System.now(),
          'Linked on arrival',
          'Story',
          null,
          'DOPP'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    // Before this, a new issue arrived with no project, and the public board - whose query
    // demands a public parent project - never showed it, with nothing anywhere saying why.
    Assert.areEqual(
      project.Id,
      [SELECT Project__c FROM Work_Item__c WHERE External_Id__c = 'jira:10600']
      .Project__c,
      'fields.project.key should resolve to the Project__c carrying that key.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Integration_Log__c],
      'A resolved link is nothing to report.'
    );
  }

  @IsTest
  static void anUnknownProjectKeyIsLoggedAndTheRecordStillSyncs() {
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10601',
          'NOPE-1',
          'In Progress',
          System.now(),
          'Belongs to a project Salesforce has not seen',
          'Story',
          null,
          'NOPE'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c created = [
      SELECT Project__c, Status__c
      FROM Work_Item__c
      WHERE External_Id__c = 'jira:10601'
    ];
    Assert.isNull(created.Project__c, 'No project to link to.');
    Assert.areEqual(
      'In Progress',
      created.Status__c,
      'The status change still lands - a missing project is not a reason to drop it.'
    );
    Assert.areEqual(
      'Processed',
      [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1]
      .Processing_Status__c,
      'The delivery itself succeeded.'
    );
    List<Integration_Log__c> logs = [
      SELECT Direction__c, Is_Success__c, Error_Message__c
      FROM Integration_Log__c
    ];
    Assert.areEqual(1, logs.size(), 'The gap is reported exactly once.');
    Assert.areEqual('Inbound', logs[0].Direction__c);
    Assert.isFalse(logs[0].Is_Success__c);
    Assert.isTrue(
      logs[0].Error_Message__c.contains('NOPE') &&
      logs[0].Error_Message__c.contains('jira:10601'),
      'The log names the key and the issue: ' + logs[0].Error_Message__c
    );
  }

  @IsTest
  static void anAmbiguousProjectKeyIsNotGuessedAt() {
    // External_Project_Key__c is not unique. Two projects carrying the same key and system
    // is a data problem to report, not a coin to toss.
    TestDataFactory.createProjects(2, true);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10602',
          'DOPP-602',
          'To Do',
          System.now(),
          'Two candidates',
          'Story',
          null,
          'DOPP'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.isNull(
      [SELECT Project__c FROM Work_Item__c WHERE External_Id__c = 'jira:10602']
      .Project__c,
      'Neither candidate should have been chosen.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Integration_Log__c],
      'And the ambiguity is reported.'
    );
  }

  @IsTest
  static void aMoveToAnotherProjectIsFollowed() {
    // The leak step 2 closes. Until now an existing link was never overridden, so an issue
    // moved in Jira from a public project to a private one kept pointing at the public one -
    // and the public board, which gates on the parent project's Is_Public__c, kept showing it
    // to anonymous visitors after its remote home had become private.
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10605', 'To Do', was);
    Project__c destination = TestDataFactory.createProjects(1, false)[0];
    destination.External_Project_Key__c = 'OTHER';
    insert destination;

    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10605',
          'OTHER-1',
          'In Progress',
          was.addMinutes(30),
          null,
          null,
          null,
          'OTHER'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c moved = [
      SELECT Project__c, Status__c
      FROM Work_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      destination.Id,
      moved.Project__c,
      'The payload named a different project, so the link follows it.'
    );
    Assert.areNotEqual(
      item.Project__c,
      moved.Project__c,
      'And it is genuinely not the project it started on.'
    );
    Assert.areEqual('In Progress', moved.Status__c, 'The rest still applies.');

    List<Integration_Log__c> logs = [
      SELECT Direction__c, Is_Success__c, Error_Message__c
      FROM Integration_Log__c
    ];
    Assert.areEqual(1, logs.size(), 'A move is reported exactly once.');
    Assert.areEqual('Inbound', logs[0].Direction__c);
    Assert.isTrue(
      logs[0].Error_Message__c.contains('DOPP') &&
      logs[0].Error_Message__c.contains('OTHER'),
      'The row names the project left and the project joined: ' +
      logs[0].Error_Message__c
    );
  }

  @IsTest
  static void aPayloadNamingTheProjectAlreadyLinkedWritesNothing() {
    // seedItem links the record to a project keyed DOPP, which is the key this payload names.
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10606', 'To Do', was);

    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10606',
          'DOPP-606',
          'In Progress',
          was.addMinutes(30),
          null,
          null,
          null,
          'DOPP'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      item.Project__c,
      [SELECT Project__c FROM Work_Item__c WHERE Id = :item.Id].Project__c,
      'Naming the project a record already has is not a move.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Integration_Log__c],
      'And nothing happened, so there is nothing to report.'
    );
  }

  @IsTest
  static void aMoveToAnUnknownProjectKeepsTheLinkItHas() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10607', 'To Do', was);

    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10607',
          'NOPE-1',
          'In Progress',
          was.addMinutes(30),
          null,
          null,
          null,
          'NOPE'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      item.Project__c,
      [SELECT Project__c FROM Work_Item__c WHERE Id = :item.Id].Project__c,
      'A lookup that failed is not a reason to null a link that works - doing so would ' +
      'hide the record from the board rather than correct it.'
    );
    List<Integration_Log__c> logs = [
      SELECT Error_Message__c
      FROM Integration_Log__c
    ];
    Assert.areEqual(1, logs.size(), 'The unfollowable move is reported.');
    Assert.isTrue(
      logs[0].Error_Message__c.contains('NOPE'),
      'And names the key it could not resolve: ' + logs[0].Error_Message__c
    );
  }

  @IsTest
  static void aMoveToAnAmbiguousProjectKeyKeepsTheLinkItHas() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10608', 'To Do', was);
    // Two projects carrying the destination key. External_Project_Key__c is not unique, and
    // choosing between candidates would move work to the wrong project silently.
    for (Project__c candidate : TestDataFactory.createProjects(2, false)) {
      candidate.External_Project_Key__c = 'TWICE';
      insert candidate;
    }

    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10608',
          'TWICE-1',
          'In Progress',
          was.addMinutes(30),
          null,
          null,
          null,
          'TWICE'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      item.Project__c,
      [SELECT Project__c FROM Work_Item__c WHERE Id = :item.Id].Project__c,
      'Neither candidate should have been chosen, and the working link stays.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Integration_Log__c],
      'And the ambiguity is reported.'
    );
  }

  @IsTest
  static void aRecordWithNoProjectIsLinkedOnItsNextDelivery() {
    // The back-fill case: every record created before project linkage existed, or by hand.
    Datetime was = System.now().addHours(-1);
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c orphan = TestDataFactory.createWorkItems(1, null, false)[0];
    orphan.External_Id__c = 'jira:10604';
    orphan.Status__c = 'To Do';
    orphan.Sync_Status__c = 'Pending';
    orphan.Remote_Last_Modified__c = was;
    insert orphan;

    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10604',
          'DOPP-604',
          'In Progress',
          was.addMinutes(30),
          null,
          null,
          null,
          'DOPP'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      project.Id,
      [SELECT Project__c FROM Work_Item__c WHERE Id = :orphan.Id].Project__c,
      'An unlinked record picks up its project the next time it is delivered.'
    );
  }

  // ---------- applying changes ----------

  @IsTest
  static void appliesANewerChange() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10039', 'To Do', was);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'In Progress',
          was.addMinutes(30)
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c updated = [
      SELECT Status__c, Sync_Status__c, Last_Synced__c, Remote_Last_Modified__c
      FROM Work_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      'In Progress',
      updated.Status__c,
      'Newer change should be applied.'
    );
    Assert.areEqual(
      'Synced',
      updated.Sync_Status__c,
      'Applying a remote change means we now agree.'
    );
    Assert.isNotNull(
      updated.Last_Synced__c,
      'Last_Synced__c should be stamped.'
    );
    Assert.areEqual(
      'Processed',
      [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1]
      .Processing_Status__c,
      'Terminal.'
    );
  }

  @IsTest
  static void storesTheSummaryAsTheWorkItemTitle() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10039', 'To Do', was);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'In Progress',
          was.addMinutes(30),
          'Reconcile the nightly Jira pull'
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      'Reconcile the nightly Jira pull',
      [SELECT Title__c FROM Work_Item__c WHERE Id = :item.Id].Title__c,
      'issue.fields.summary is the task title and belongs in Title__c.'
    );
  }

  @IsTest
  static void leavesAnExistingTitleAloneWhenThePayloadCarriesNoSummary() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10039', 'To Do', was);
    item.Title__c = 'Title we already hold';
    update item;

    // A delivery with no summary is not a retitling. Writing the null through would blank the
    // card heading on every status-only webhook.
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'In Progress',
          was.addMinutes(30),
          null
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c updated = [
      SELECT Status__c, Title__c
      FROM Work_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      'Title we already hold',
      updated.Title__c,
      'A payload with no summary must not blank the title.'
    );
    Assert.areEqual(
      'In Progress',
      updated.Status__c,
      'The rest of the payload still applies.'
    );
  }

  @IsTest
  static void truncatesASummaryTooLongForTheFieldRatherThanFailingTheDelivery() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10039', 'To Do', was);
    String longSummary = 'x'.repeat(400);

    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'In Progress',
          was.addMinutes(30),
          longSummary
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c updated = [
      SELECT Status__c, Title__c
      FROM Work_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      255,
      updated.Title__c.length(),
      'Title should be cut to the field length, not rejected.'
    );
    Assert.areEqual(
      'In Progress',
      updated.Status__c,
      'An over-long title must not cost us the status change.'
    );
    Assert.areEqual(
      'Processed',
      [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1]
      .Processing_Status__c,
      'Delivery still terminal and successful.'
    );
  }

  @IsTest
  static void translatesJiraVocabularyThroughTheSharedMapping() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10039', 'To Do', was);
    // Jira says 'Resolved'; our vocabulary calls that 'Done'. Same table the outbound path uses.
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'Resolved',
          was.addMinutes(30)
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      'Done',
      [SELECT Status__c FROM Work_Item__c WHERE Id = :item.Id].Status__c,
      'Alias should normalize.'
    );
  }

  @IsTest
  static void anUnmappedStatusLandsOnUnspecifiedWithoutBreakingTheValidationRule() {
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10039', 'To Do', was);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'Blocked',
          was.addMinutes(30)
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Work_Item__c updated = [
      SELECT Status__c, Sync_Status__c
      FROM Work_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      'Unspecified',
      updated.Status__c,
      'An unmapped Jira status lands on the catch-all.'
    );
    // Synced alongside Unspecified violates Sync_Status_Requires_Known_Status from build 01.
    Assert.areEqual(
      'Pending',
      updated.Sync_Status__c,
      'Must not claim Synced with an unmapped status.'
    );
    Webhook_Event__c event = [
      SELECT Processing_Status__c, Error_Message__c
      FROM Webhook_Event__c
      LIMIT 1
    ];
    Assert.areEqual(
      'Processed',
      event.Processing_Status__c,
      'It was applied, so it is processed.'
    );
    Assert.isTrue(
      event.Error_Message__c.contains('Blocked'),
      'The unmapped status should be named: ' + event.Error_Message__c
    );
  }

  @IsTest
  static void anUnknownExternalIdCreatesTheWorkItem() {
    // An issue created in Jira that Salesforce has never seen. Normal, not an error.
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10500',
          'DOPP-99',
          'In Progress',
          System.now()
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    List<Work_Item__c> created = [
      SELECT External_Id__c, External_Key__c, Status__c, External_System__c
      FROM Work_Item__c
    ];
    Assert.areEqual(1, created.size(), 'An unseen issue should be created.');
    Assert.areEqual(
      'jira:10500',
      created[0].External_Id__c,
      'Stored namespaced, matching the upsert key.'
    );
    Assert.areEqual(
      'DOPP-99',
      created[0].External_Key__c,
      'Key recorded so the record is identifiable.'
    );
    Assert.areEqual('In Progress', created[0].Status__c, 'Status applied.');
    Assert.areEqual(
      'Processed',
      [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1]
      .Processing_Status__c,
      'Terminal.'
    );
  }

  // ---------- ordering and idempotency ----------

  @IsTest
  static void theSameDeliveryTwiceProducesOneWorkItem() {
    Datetime updated = System.now();
    String payload = JiraWebhookPayloadFactory.issueUpdated(
      '10039',
      'DOPP-15',
      'In Progress',
      updated
    );
    List<Webhook_Event__c> events = deliver(
      new List<String>{ payload, payload }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Work_Item__c],
      'A duplicate delivery must not duplicate the record.'
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE Processing_Status__c = 'Processed'
      ],
      'One applied.'
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE Processing_Status__c = 'Ignored'
      ],
      'One ignored.'
    );
  }

  @IsTest
  static void anOlderDeliveryArrivingLateIsIgnored() {
    Datetime now = System.now();
    Work_Item__c item = seedItem('jira:10039', 'Done', now);
    // Jira does not guarantee ordering. This one describes a state we have already moved past.
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'To Do',
          now.addMinutes(-30)
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      'Done',
      [SELECT Status__c FROM Work_Item__c WHERE Id = :item.Id].Status__c,
      'Stale data must not win.'
    );
    Webhook_Event__c event = [
      SELECT Processing_Status__c, Error_Message__c
      FROM Webhook_Event__c
      LIMIT 1
    ];
    Assert.areEqual(
      'Ignored',
      event.Processing_Status__c,
      'Ignored is a success, not a failure.'
    );
    Assert.isTrue(
      event.Error_Message__c.contains('not newer'),
      'Reason recorded: ' + event.Error_Message__c
    );
  }

  @IsTest
  static void onlyTheNewestDeliveryInABatchIsApplied() {
    Datetime base = System.now().addHours(-1);
    seedItem('jira:10039', 'To Do', base);

    Test.startTest();
    WorkItemInboundProcessor.process(
      deliver(
        new List<String>{
          JiraWebhookPayloadFactory.issueUpdated(
            '10039',
            'DOPP-15',
            'In Progress',
            base.addMinutes(10)
          ),
          JiraWebhookPayloadFactory.issueUpdated(
            '10039',
            'DOPP-15',
            'Done',
            base.addMinutes(30)
          ),
          JiraWebhookPayloadFactory.issueUpdated(
            '10039',
            'DOPP-15',
            'In Review',
            base.addMinutes(20)
          )
        }
      )
    );
    Test.stopTest();

    // Arrival order must not decide the outcome; the timestamps must.
    Assert.areEqual(
      'Done',
      [SELECT Status__c FROM Work_Item__c LIMIT 1].Status__c,
      'Newest by timestamp wins.'
    );
    Assert.areEqual(
      2,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE Processing_Status__c = 'Ignored'
      ],
      'Others superseded.'
    );
  }

  // ---------- loop prevention ----------

  @IsTest
  static void inboundProcessingEnqueuesNoOutboundCall() {
    Datetime was = System.now().addHours(-1);
    seedItem('jira:10039', 'To Do', was);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'In Progress',
          was.addMinutes(30)
        )
      }
    );

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    WorkItemInboundProcessor.process(events);
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      before,
      after,
      'Applying a webhook must not push straight back to Jira.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Integration_Log__c],
      'And no callout should have been logged.'
    );
  }

  @IsTest
  static void anOrdinaryStatusChangeDoesEnqueueAnOutboundCall() {
    // Negative control. Without this, the test above would pass even if suppression were
    // broken and the trigger simply never fired.
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = seedItem('jira:10039', 'To Do', System.now());

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    update new Work_Item__c(Id = item.Id, Status__c = 'In Progress');
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      before + 1,
      after,
      'A genuine Salesforce-side status change should push outbound.'
    );
  }

  @IsTest
  static void aPreviouslySyncedRecordStillPushesWhenItsStatusChanges() {
    // Regression guard. The adapter skips its callout for anything marked Synced, so without
    // before-update staging a record synced once would never sync again - and would report
    // success while Jira never heard about it. Asserting on the enqueue alone missed this:
    // the job ran, made no callout, and stamped the record Synced anyway.
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.External_Id__c = 'jira:10039';
    item.Status__c = 'To Do';
    item.Sync_Status__c = 'Synced'; // the state that used to go silent
    insert item;

    Test.startTest();
    update new Work_Item__c(Id = item.Id, Status__c = 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      2,
      mock.callCount(),
      'A real status change must reach Jira: list, then transition.'
    );
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Integration_Log__c],
      'And the callouts must be logged, which is how this failure was visible at all.'
    );
    Assert.areEqual(
      'Synced',
      [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id]
      .Sync_Status__c,
      'Only after a real push may it claim to be synced.'
    );
  }

  @IsTest
  static void stagingLeavesAnExplicitSyncStatusAlone() {
    // A caller that sets Sync_Status__c in the same update means it; staging must not override.
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    Work_Item__c item = seedItem('jira:10039', 'To Do', System.now());

    Test.startTest();
    update new Work_Item__c(
      Id = item.Id,
      Status__c = 'In Progress',
      Sync_Status__c = 'Failed'
    );
    Test.stopTest();

    Assert.areNotEqual(
      'Pending',
      [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id]
      .Sync_Status__c,
      'An explicitly supplied Sync_Status__c beats the inferred one.'
    );
  }

  @IsTest
  static void inboundKeepsItsOwnSyncStatusThroughStaging() {
    // Inbound sets Synced deliberately. Staging runs on the same DML and must stand down.
    Datetime was = System.now().addHours(-1);
    Work_Item__c item = seedItem('jira:10039', 'To Do', was);
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10039',
          'DOPP-15',
          'In Progress',
          was.addMinutes(30)
        )
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      'Synced',
      [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id]
      .Sync_Status__c,
      'Suppression must stop staging from downgrading an inbound-applied change to Pending.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Integration_Log__c],
      'And still no outbound traffic.'
    );
  }

  @IsTest
  static void awriteThatChangesNoStatusEnqueuesNothing() {
    // Build 02 writes Sync_Status__c and Last_Synced__c back after every sync. Without the
    // delta check those writes would re-trigger the sync that produced them.
    Work_Item__c item = seedItem('jira:10039', 'To Do', System.now());

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    update new Work_Item__c(Id = item.Id, Sync_Status__c = 'Failed');
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      before,
      after,
      'Only a Status__c change is a reason to sync.'
    );
  }

  @IsTest
  static void suppressionUnwindsByDepthNotByFlag() {
    SyncContext.reset();
    Assert.isFalse(SyncContext.isOutboundSuppressed(), 'Clean start.');
    SyncContext.suppressOutbound();
    SyncContext.suppressOutbound();
    SyncContext.resumeOutbound();
    Assert.isTrue(
      SyncContext.isOutboundSuppressed(),
      'An inner resume must not lift an outer block.'
    );
    SyncContext.resumeOutbound();
    Assert.isFalse(
      SyncContext.isOutboundSuppressed(),
      'Balanced calls clear it.'
    );
    SyncContext.resumeOutbound();
    Assert.isFalse(
      SyncContext.isOutboundSuppressed(),
      'Extra resumes must not go negative.'
    );
  }

  // ---------- bad input ----------

  @IsTest
  static void malformedJsonFailsTheEventAndNothingElse() {
    List<Webhook_Event__c> events = deliver(
      new List<String>{ 'this is not json at all' }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events); // must not throw
    Test.stopTest();

    Webhook_Event__c event = [
      SELECT Processing_Status__c, Error_Message__c
      FROM Webhook_Event__c
      LIMIT 1
    ];
    Assert.areEqual(
      'Failed',
      event.Processing_Status__c,
      'Unparseable input is a failed event.'
    );
    Assert.isTrue(
      event.Error_Message__c.contains('Malformed JSON'),
      'Reason recorded: ' + event.Error_Message__c
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Work_Item__c],
      'Nothing should have been written.'
    );
  }

  @IsTest
  static void structurallyValidJsonMissingWhatWeNeedFailsCleanly() {
    List<Webhook_Event__c> events = deliver(
      new List<String>{
        '{"webhookEvent":"jira:issue_updated"}',
        '{"webhookEvent":"jira:issue_updated","issue":{"key":"DOPP-1","fields":{}}}',
        '{"webhookEvent":"jira:issue_updated","issue":{"id":"10039","fields":{"status":{"name":"Done"}}}}'
      }
    );

    Test.startTest();
    WorkItemInboundProcessor.process(events);
    Test.stopTest();

    Assert.areEqual(
      3,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE Processing_Status__c = 'Failed'
      ],
      'No issue, no id, and no timestamp are each a clean failure.'
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Work_Item__c], 'Nothing written.');
  }

  @IsTest
  static void emptyAndNullInputAreNoOps() {
    Test.startTest();
    WorkItemInboundProcessor.process(null);
    WorkItemInboundProcessor.process(new List<Webhook_Event__c>());
    WorkItemInboundProcessor.handle(new List<Webhook_Event_Received__e>());
    Test.stopTest();
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Work_Item__c],
      'Nothing to do, nothing done.'
    );
  }

  // ---------- bulk ----------

  @IsTest
  static void handlesTwoHundredDeliveries() {
    Datetime base = System.now();
    List<String> payloads = new List<String>();
    for (Integer i = 0; i < 200; i++) {
      payloads.add(
        JiraWebhookPayloadFactory.issueUpdated(
          String.valueOf(20000 + i),
          'DOPP-' + i,
          'In Progress',
          base
        )
      );
    }
    List<Webhook_Event__c> events = deliver(payloads);

    Test.startTest();
    Integer dmlBefore = Limits.getDmlStatements();
    WorkItemInboundProcessor.process(events);
    Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
    Test.stopTest();

    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Work_Item__c],
      '200 distinct issues, 200 records.'
    );
    Assert.areEqual(
      200,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE Processing_Status__c = 'Processed'
      ],
      'All processed.'
    );
    // One upsert for the work items, one update for the events, whatever the volume.
    Assert.areEqual(
      2,
      dmlUsed,
      'DML must not scale with the number of events.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Integration_Log__c],
      'And no outbound traffic from any of it.'
    );
  }
}
