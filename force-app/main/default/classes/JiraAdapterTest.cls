/**
 * Covers the wire contract with Jira: what goes out, and how each class of answer is classified.
 */
@IsTest
private class JiraAdapterTest {
  private static Work_Item__c workItem(String status, String syncStatus) {
    return new Work_Item__c(
      External_Id__c = 'jira:10023',
      External_System__c = 'Jira',
      Status__c = status,
      Sync_Status__c = syncStatus
    );
  }

  // ---------- what we send ----------

  @IsTest
  static void sendsTheTransitionsPathWithTheNamespaceStripped() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    // The stored id is jira:10023; Jira must receive 10023 or it answers 404.
    String expected = 'callout:Jira_Classic/rest/api/3/issue/10023/transitions';
    Assert.areEqual(
      expected,
      mock.firstCall().endpoint,
      'Namespace must be stripped from the path.'
    );
    Assert.isFalse(
      mock.firstCall().endpoint.contains('jira%3A'),
      'The prefix must not survive URL encoding.'
    );
  }

  @IsTest
  static void sendsGetThenPostWithTheChosenTransitionId() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      2,
      mock.callCount(),
      'A status change is two calls: list, then apply.'
    );
    Assert.areEqual(
      'GET',
      mock.captured[0].method,
      'First call lists transitions.'
    );
    Assert.areEqual(
      'POST',
      mock.captured[1].method,
      'Second call applies one.'
    );
    // Transition 11 is the one whose to.name is "In Progress"; its own name is "Start Progress".
    // Asserting on 11 is what proves we matched the destination status, not the button label.
    Assert.areEqual(
      '{"transition":{"id":"11"}}',
      mock.captured[1].body,
      'Wrong transition id posted.'
    );
    Assert.areEqual(
      SyncResult.Outcome.SUCCESS,
      result.outcome,
      'Should have succeeded.'
    );
  }

  @IsTest
  static void setsJsonHeadersAndOmitsContentTypeWhenThereIsNoBody() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      'application/json',
      mock.captured[0].accept,
      'GET should accept JSON.'
    );
    Assert.isNull(
      mock.captured[0].contentType,
      'A bodiless GET should not declare a content type.'
    );
    Assert.areEqual(
      'application/json',
      mock.captured[1].accept,
      'POST should accept JSON.'
    );
    Assert.areEqual(
      'application/json',
      mock.captured[1].contentType,
      'POST sends JSON.'
    );
  }

  @IsTest
  static void matchesAJiraStatusNameThroughTheAliasTable() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.ALIAS_ONLY
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('Done', 'Pending'), 'Done');
    Test.stopTest();

    // Jira calls it "Resolved"; we call it "Done".
    Assert.areEqual(
      SyncResult.Outcome.SUCCESS,
      result.outcome,
      'Alias should have matched: ' + result.message
    );
    Assert.areEqual(
      '{"transition":{"id":"41"}}',
      mock.captured[1].body,
      'Should have posted the alias transition.'
    );
  }

  // ---------- how answers are classified ----------

  @IsTest
  static void unavailableTransitionIsABusinessOutcomeNotAFailure() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.NO_MATCHING_TRANSITION
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
      result.outcome,
      'Should be a handled outcome.'
    );
    Assert.isTrue(
      result.isBusinessOutcome(),
      'A workflow saying no is not a fault.'
    );
    Assert.isFalse(result.isSuccess(), 'Nothing was transitioned.');
    Assert.areEqual(
      1,
      mock.callCount(),
      'Must not POST when no transition matched.'
    );
    // "Surface it clearly" means naming what was actually on offer.
    Assert.isTrue(
      result.message.contains('Done'),
      'Message should list what was available: ' + result.message
    );
  }

  @IsTest
  static void terminalIssueReportsNoneAvailable() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.NO_TRANSITIONS_AT_ALL)
    );

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('Done', 'Pending'), 'Done');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
      result.outcome,
      'Nowhere to go.'
    );
    Assert.isTrue(
      result.message.contains('none'),
      'Should say none were available: ' + result.message
    );
  }

  @IsTest
  static void unauthorizedIsDistinctFromOtherFailures() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED)
    );

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.UNAUTHORIZED,
      result.outcome,
      '401 should classify as UNAUTHORIZED.'
    );
    Assert.areEqual(
      401,
      result.statusCode,
      'Status code should be carried through.'
    );
    Assert.isFalse(
      result.isBusinessOutcome(),
      'A bad token is a fault, not a business answer.'
    );
  }

  @IsTest
  static void rateLimitIsDistinctFromAServerError() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.RATE_LIMITED)
    );

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.RATE_LIMITED,
      result.outcome,
      '429 should be its own outcome.'
    );
    Assert.areEqual(
      429,
      result.statusCode,
      'Status code should be carried through.'
    );
  }

  @IsTest
  static void serverErrorIsRemoteError() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.SERVER_ERROR)
    );

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.REMOTE_ERROR,
      result.outcome,
      '500 should be REMOTE_ERROR.'
    );
    Assert.areEqual(
      500,
      result.statusCode,
      'Status code should be carried through.'
    );
  }

  @IsTest
  static void failureOnTheSecondLegIsStillReported() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.POST_FAILS
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      2,
      mock.callCount(),
      'The listing succeeded, so the POST was attempted.'
    );
    Assert.areEqual(
      SyncResult.Outcome.REMOTE_ERROR,
      result.outcome,
      'A failed POST must not read as success.'
    );
  }

  @IsTest
  static void unparseableBodyIsARemoteErrorNotAnUnhandledException() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.MALFORMED_BODY)
    );

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.REMOTE_ERROR,
      result.outcome,
      'Garbage should be caught, not thrown.'
    );
    Assert.isTrue(
      result.message.contains('parse'),
      'Message should say what went wrong: ' + result.message
    );
  }

  // ---------- requests we refuse to make ----------

  @IsTest
  static void rejectsBadRequestsWithoutCallingJira() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);
    JiraAdapter adapter = new JiraAdapter();

    Test.startTest();
    Map<String, SyncResult> results = new Map<String, SyncResult>{
      'null item' => adapter.updateStatus(null, 'Done'),
      'blank target' => adapter.updateStatus(
        workItem('To Do', 'Pending'),
        '   '
      ),
      'unspecified target' => adapter.updateStatus(
        workItem('To Do', 'Pending'),
        'Unspecified'
      ),
      'unknown status' => adapter.updateStatus(
        workItem('To Do', 'Pending'),
        'Marinating'
      ),
      'wrong system' => adapter.updateStatus(
        new Work_Item__c(
          External_Id__c = 'asana:998877',
          Status__c = 'To Do',
          Sync_Status__c = 'Pending'
        ),
        'Done'
      ),
      'unqualified id' => adapter.updateStatus(
        new Work_Item__c(
          External_Id__c = '10023',
          Status__c = 'To Do',
          Sync_Status__c = 'Pending'
        ),
        'Done'
      )
    };
    Test.stopTest();

    for (String label : results.keySet()) {
      Assert.areEqual(
        SyncResult.Outcome.BAD_REQUEST,
        results.get(label).outcome,
        label + ' should be rejected as a bad request.'
      );
    }
    Assert.areEqual(
      0,
      mock.callCount(),
      'A rejected request must not reach Jira.'
    );
    Assert.areEqual(
      0,
      adapter.drainLogs().size(),
      'No callout means no callout log.'
    );
  }

  @IsTest
  static void skipsTheCalloutOnlyWhenTheRemoteIsBelievedToAgree() {
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    SyncResult settled = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Synced'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.ALREADY_IN_TARGET_STATUS,
      settled.outcome,
      'Nothing to do.'
    );
    Assert.isTrue(
      settled.isSuccess(),
      'Already being there counts as success.'
    );
    Assert.areEqual(0, mock.callCount(), 'No callout should be made.');
  }

  @IsTest
  static void doesNotSkipWhenTheLastSyncDidNotSucceed() {
    // Regression guard. The service passes item.Status__c as its own target, so a skip test
    // based on status alone is always true and nothing would ever sync. Sync_Status__c is
    // what makes the "already there" belief credible.
    JiraCalloutMock mock = new JiraCalloutMock(
      JiraCalloutMock.Scenario.TRANSITION_OK
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.SUCCESS,
      result.outcome,
      'A pending item must actually sync.'
    );
    Assert.areEqual(
      2,
      mock.callCount(),
      'Both callouts should have been made.'
    );
  }

  // ---------- logging ----------

  @IsTest
  static void buffersOneLogPerCalloutAndClearsOnDrain() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    JiraAdapter adapter = new JiraAdapter();

    Test.startTest();
    adapter.updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    List<Integration_Log__c> logs = adapter.drainLogs();
    Assert.areEqual(2, logs.size(), 'One row per callout.');
    Assert.areEqual('GET', logs[0].HTTP_Method__c, 'First row is the listing.');
    Assert.areEqual(
      'POST',
      logs[1].HTTP_Method__c,
      'Second row is the transition.'
    );
    Assert.areEqual(
      204,
      logs[1].Status_Code__c.intValue(),
      'Jira answers 204 to a transition.'
    );
    for (Integration_Log__c log : logs) {
      Assert.areEqual(
        'Outbound',
        log.Direction__c,
        'These are outbound calls.'
      );
      Assert.isTrue(log.Is_Success__c, '2xx should be recorded as success.');
      Assert.isTrue(log.Duration_ms__c >= 0, 'Duration should be recorded.');
      Assert.isTrue(
        log.Endpoint__c.contains('/transitions'),
        'Endpoint should be recorded.'
      );
    }
    Assert.areEqual(
      0,
      adapter.drainLogs().size(),
      'Draining should empty the buffer.'
    );
  }

  @IsTest
  static void logsFailedCalloutsToo() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED)
    );
    JiraAdapter adapter = new JiraAdapter();

    Test.startTest();
    adapter.updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
    Test.stopTest();

    List<Integration_Log__c> logs = adapter.drainLogs();
    Assert.areEqual(
      1,
      logs.size(),
      'The failed listing should still be logged.'
    );
    Assert.areEqual(
      401,
      logs[0].Status_Code__c.intValue(),
      'Real status code should be recorded.'
    );
    Assert.isFalse(logs[0].Is_Success__c, '401 is not a success.');
    Assert.isTrue(
      logs[0].Response_Body__c.contains('authenticated'),
      'Response body should be captured.'
    );
  }

  // ---------- fetchAvailableTransitions ----------

  @IsTest
  static void fetchReturnsVendorNeutralOptions() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    Test.startTest();
    List<TransitionOption> options = new JiraAdapter()
      .fetchAvailableTransitions('jira:10023');
    Test.stopTest();

    Assert.areEqual(
      3,
      options.size(),
      'All three transitions should come back.'
    );
    Map<String, String> idByStatus = new Map<String, String>();
    for (TransitionOption option : options) {
      idByStatus.put(option.targetStatus, option.id);
    }
    Assert.areEqual(
      '11',
      idByStatus.get('In Progress'),
      'Options carry the destination status, not the label.'
    );
    Assert.areEqual(
      '31',
      idByStatus.get('Done'),
      'Options carry the destination status, not the label.'
    );
  }

  @IsTest
  static void fetchThrowsOnTechnicalFailureSoEmptyMeansTerminal() {
    // An empty list has to mean "nowhere to go". If a 500 also returned empty, the caller
    // could not tell a terminal issue from a broken integration.
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.SERVER_ERROR)
    );

    Test.startTest();
    try {
      new JiraAdapter().fetchAvailableTransitions('jira:10023');
      Assert.fail('A 500 should raise, not return empty.');
    } catch (AdapterException e) {
      Assert.isTrue(
        e.getMessage().contains('500'),
        'Message should carry the status: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void fetchRejectsAnIdFromAnotherSystem() {
    Test.startTest();
    try {
      new JiraAdapter().fetchAvailableTransitions('asana:998877');
      Assert.fail('A non-Jira id should be refused.');
    } catch (AdapterException e) {
      Assert.isTrue(
        e.getMessage().contains('asana'),
        'Message should name the offending id.'
      );
    }
    Test.stopTest();
  }

  // ---------- inbound: reading a delivery ----------

  /**
   * Deliveries the adapter can be handed, with real ids so correlation is real.
   *
   * Inserted as Processing rather than Pending on purpose: WebhookEventTriggerHandler publishes
   * a platform event for a Pending row, and the subscriber would then process these payloads at
   * Test.stopTest. This class is about what the adapter returns, not about what the processor
   * does with it.
   */
  private static List<Webhook_Event__c> deliveries(List<String> payloads) {
    List<Webhook_Event__c> events = new List<Webhook_Event__c>();
    for (String payload : payloads) {
      events.add(
        new Webhook_Event__c(
          Source_System__c = ExternalSystem.JIRA,
          Received_At__c = System.now(),
          Signature_Valid__c = true,
          Processing_Status__c = DeliveryStatus.PROCESSING,
          Raw_Payload__c = payload
        )
      );
    }
    insert events;
    return events;
  }

  // ---------- the batch shape (build 07 step 3) ----------

  @IsTest
  static void aBatchComesBackInTheOrderItWasGiven() {
    List<String> payloads = new List<String>();
    for (Integer i = 0; i < 5; i++) {
      payloads.add(
        JiraWebhookPayloadFactory.issueUpdated(
          '107' + i,
          'DOPP-7' + i,
          'In Progress',
          System.now()
        )
      );
    }
    List<Webhook_Event__c> events = deliveries(payloads);

    Test.startTest();
    List<InboundChange> changes = new JiraAdapter().parseInbound(events);
    Test.stopTest();

    Assert.areEqual(5, changes.size(), 'Five deliveries, five changes.');
    for (Integer i = 0; i < 5; i++) {
      Assert.areEqual(
        'jira:107' + i,
        changes[i].externalId,
        'Position ' + i + ' should be the delivery at that position.'
      );
      Assert.areEqual(
        events[i].Id,
        changes[i].sourceEventId,
        'And each change names the delivery it was read from, which is what lets the ' +
        'processor correlate a list that is allowed to come back shorter.'
      );
    }
  }

  @IsTest
  static void oneUnreadableDeliveryDoesNotDiscardTheBatch() {
    List<Webhook_Event__c> events = deliveries(
      new List<String>{
        JiraWebhookPayloadFactory.issueUpdated(
          '10801',
          'DOPP-801',
          'To Do',
          System.now()
        ),
        'this is not json at all',
        JiraWebhookPayloadFactory.issueUpdated(
          '10803',
          'DOPP-803',
          'Done',
          System.now()
        )
      }
    );

    Test.startTest();
    JiraAdapter adapter = new JiraAdapter();
    List<InboundChange> changes = adapter.parseInbound(events);
    List<Integration_Log__c> logs = adapter.drainLogs();
    Test.stopTest();

    Assert.areEqual(
      3,
      changes.size(),
      'The unreadable one comes back too, carrying its failure, so the processor can ' +
      'retire that delivery rather than leave it Pending for ever.'
    );
    Assert.isTrue(changes[0].isUsable(), 'First is fine.');
    Assert.isFalse(changes[1].isUsable(), 'Second is the broken one.');
    Assert.isTrue(
      changes[2].isUsable(),
      'And the third still parsed - one bad body must not cost the rest of the batch.'
    );
    Assert.areEqual('jira:10803', changes[2].externalId);

    Assert.areEqual(
      1,
      logs.size(),
      'One row, for the one delivery that failed.'
    );
    Assert.areEqual('Inbound', logs[0].Direction__c);
    Assert.isFalse(logs[0].Is_Success__c);
    Assert.isTrue(
      logs[0].Error_Message__c.contains(String.valueOf(events[1].Id)),
      'The row names the delivery: ' + logs[0].Error_Message__c
    );
  }

  @IsTest
  static void anEmptyBatchReturnsNothingAndTouchesNothing() {
    // A mock is registered although nothing should reach it. Without one a stray callout
    // would throw before the assertion below could report it, and "it threw" is a weaker
    // fact than "it called out twice".
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );

    // Both readings are taken inside the startTest window. Test.stopTest restores the outer
    // limits context, so a count taken after it reports the callouts made BEFORE startTest -
    // which is zero either way, and an assertion that can never fail. Found by breaking this
    // test on purpose: with a callout added to parseInbound it still passed.
    Test.startTest();
    Integer calloutsBefore = Limits.getCallouts();
    List<InboundChange> fromEmpty = new JiraAdapter()
      .parseInbound(new List<Webhook_Event__c>());
    List<InboundChange> fromNull = new JiraAdapter().parseInbound(null);
    Integer calloutsAfter = Limits.getCallouts();
    Test.stopTest();

    Assert.areEqual(0, fromEmpty.size(), 'Nothing in, nothing out.');
    Assert.areEqual(0, fromNull.size(), 'And null is not a reason to throw.');
    Assert.areEqual(
      calloutsBefore,
      calloutsAfter,
      'No delivery means no callout. Jira needs none at all, but the assertion is what ' +
      'stops an adapter that does need them from calling out over an empty list.'
    );
  }

  /**
   * One payload through the batch-shaped parseInbound.
   *
   * parseInbound takes deliveries rather than a body as of build 07 step 3, so that an adapter
   * whose payloads need hydrating can fetch what a whole batch refers to in one go. The single
   * payload cases below are about Jira's payload shape, not about batching, and this keeps them
   * reading that way.
   */
  private static InboundChange parseOne(JiraAdapter adapter, String payload) {
    List<InboundChange> changes = adapter.parseInbound(
      new List<Webhook_Event__c>{
        new Webhook_Event__c(Raw_Payload__c = payload)
      }
    );
    Assert.areEqual(
      1,
      changes.size(),
      'One delivery in, one change out - usable or not.'
    );
    return changes[0];
  }

  @IsTest
  static void parsesAFullPayloadIntoAVendorNeutralChange() {
    Datetime updated = Datetime.newInstanceGmt(2026, 9, 12, 19, 13, 41);
    String payload = JiraWebhookPayloadFactory.issueUpdated(
      '10039',
      'DOPP-15',
      'Resolved',
      updated,
      'Reconcile the nightly Jira pull',
      'Sub-task',
      '10038',
      'DOPP'
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    Assert.areEqual('jira:issue_updated', change.eventType);
    Assert.areEqual('jira:10039', change.externalId, 'issue.id, namespaced.');
    Assert.areEqual('DOPP-15', change.externalKey);
    Assert.areEqual('Reconcile the nightly Jira pull', change.title);
    Assert.areEqual(
      'Resolved',
      change.remoteStatus,
      'Jira\'s word, kept for logs.'
    );
    Assert.areEqual(
      'Done',
      change.normalizedStatus,
      'Ours, through the alias table.'
    );
    Assert.areEqual('Sub-task', change.remoteType);
    Assert.areEqual('Task', change.normalizedType);
    Assert.areEqual(
      'jira:10038',
      change.parentExternalId,
      'Parent reference, namespaced.'
    );
    Assert.areEqual(
      'DOPP',
      change.projectKey,
      'The project key, not its numeric id.'
    );
    Assert.areEqual(
      updated,
      change.remoteUpdated,
      'issue.fields.updated, not the envelope.'
    );
  }

  @IsTest
  static void aStatusOnlyPayloadCarriesNothingOptional() {
    // The shape of most real deliveries: a transition with no summary, type, parent or project.
    String payload = JiraWebhookPayloadFactory.issueUpdated(
      '10039',
      'DOPP-15',
      'In Progress',
      System.now(),
      null,
      null,
      null,
      null
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    Assert.isNull(
      change.title,
      'Not carried means null, so the processor leaves the field alone.'
    );
    Assert.isNull(change.normalizedType);
    Assert.isNull(change.parentExternalId);
    Assert.isNull(change.projectKey);
    Assert.areEqual('In Progress', change.normalizedStatus);
  }

  @IsTest
  static void aBlankIssueTypeNameCountsAsAbsentNotUnmapped() {
    String payload =
      '{"webhookEvent":"jira:issue_updated","issue":{"id":"10039","key":"DOPP-15",' +
      '"fields":{"issuetype":{"name":""},"status":{"name":"Done"},' +
      '"updated":"2026-09-12T19:13:41.000+0000"}}}';

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    // Writing Unspecified over a known type on the strength of malformed input would be worse
    // than leaving it alone.
    Assert.isNull(
      change.normalizedType,
      'A nameless issuetype is treated as not sent.'
    );
  }

  @IsTest
  static void anOverLongSummaryIsCutToTheFieldRatherThanRefused() {
    String payload = JiraWebhookPayloadFactory.issueUpdated(
      '10039',
      'DOPP-15',
      'To Do',
      System.now(),
      'x'.repeat(400)
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    Assert.areEqual(255, change.title.length(), 'Title__c is 255 wide.');
    Assert.isTrue(change.title.endsWith('...'), 'And the cut is visible.');
  }

  @IsTest
  static void unusablePayloadsSayWhyWithoutThrowing() {
    JiraAdapter adapter = new JiraAdapter();
    Map<String, String> expected = new Map<String, String>{
      '' => 'Empty payload',
      'this is not json at all' => 'Malformed JSON',
      '{"webhookEvent":"jira:issue_updated"}' => 'no issue object',
      '{"issue":{"key":"DOPP-1","fields":{}}}' => 'no issue id',
      '{"issue":{"id":"10039"}}' => 'no issue fields',
      '{"issue":{"id":"10039","fields":{"status":{"name":"Done"}}}}' => 'updated timestamp'
    };
    for (String payload : expected.keySet()) {
      InboundChange change = parseOne(adapter, payload);
      Assert.isFalse(change.isUsable(), 'Should be unusable: ' + payload);
      Assert.isTrue(
        change.failure.contains(expected.get(payload)),
        'For ' +
          payload +
          ' expected "' +
          expected.get(payload) +
          '", got: ' +
          change.failure
      );
    }
  }

  @IsTest
  static void parsesJirasFourDigitOffsetTimestamps() {
    Datetime expected = Datetime.newInstanceGmt(2026, 9, 12, 19, 13, 41);
    Assert.areEqual(
      expected,
      JiraAdapter.parseIso('2026-09-12T19:13:41.000+0000'),
      'Jira wire format.'
    );
    Assert.areEqual(
      expected,
      JiraAdapter.parseIso('2026-09-12T19:13:41.000+00:00'),
      'RFC-3339 offset.'
    );
    // Real Jira sends the site's local offset, not UTC. The first live payload arrived as
    // -0700 and rolled over a date boundary; the fixture factory only ever emits +0000, so
    // nothing in this suite covered a negative offset until it turned up in production.
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 9, 13, 4, 18, 24),
      JiraAdapter.parseIso('2026-09-12T21:18:24.000-0700'),
      'A negative offset must convert to UTC and carry the date forward.'
    );
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 9, 12, 14, 30, 0),
      JiraAdapter.parseIso('2026-09-13T01:30:00.000+1100'),
      'A large positive offset must carry the date backward.'
    );
    Assert.isNull(
      JiraAdapter.parseIso('not a date'),
      'Garbage yields null, not an exception.'
    );
    Assert.isNull(JiraAdapter.parseIso(null), 'Null yields null.');
  }
}
