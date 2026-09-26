/**
 * Covers the wire contract with Jira: what goes out, and how each class of answer is classified.
 */
@IsTest
private class JiraAdapterTest {
  /** A fresh set each call: the adapter must never be handed a set a test also reads. */
  private static Set<SyncField> statusOnly() {
    return new Set<SyncField>{ SyncField.STATUS };
  }

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
    new JiraAdapter().push(workItem('In Progress', 'Pending'), statusOnly());
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
      .push(workItem('In Progress', 'Pending'), statusOnly());
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
    new JiraAdapter().push(workItem('In Progress', 'Pending'), statusOnly());
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
      .push(workItem('Done', 'Pending'), statusOnly());
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
      .push(workItem('In Progress', 'Pending'), statusOnly());
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
    // Two reads: the transitions, then the issue's own status - it might already be there. No
    // POST, because nothing lands on the target.
    Assert.areEqual(2, mock.callCount());
    for (JiraCalloutMock.CapturedRequest call : mock.captured) {
      Assert.areEqual(
        'GET',
        call.method,
        'Must not POST when no transition matched.'
      );
    }
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
      .push(workItem('Done', 'Pending'), statusOnly());
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
      .push(workItem('In Progress', 'Pending'), statusOnly());
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
      .push(workItem('In Progress', 'Pending'), statusOnly());
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
      .push(workItem('In Progress', 'Pending'), statusOnly());
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
      .push(workItem('In Progress', 'Pending'), statusOnly());
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
      .push(workItem('In Progress', 'Pending'), statusOnly());
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
      'null item' => adapter.push(null, statusOnly()),
      'blank status' => adapter.push(workItem('   ', 'Pending'), statusOnly()),
      'unspecified status' => adapter.push(
        workItem('Unspecified', 'Pending'),
        statusOnly()
      ),
      'unknown status' => adapter.push(
        workItem('Marinating', 'Pending'),
        statusOnly()
      ),
      'wrong system' => adapter.push(
        new Work_Item__c(
          External_Id__c = 'asana:998877',
          Status__c = 'To Do',
          Sync_Status__c = 'Pending'
        ),
        statusOnly()
      ),
      'unqualified id' => adapter.push(
        new Work_Item__c(
          External_Id__c = '10023',
          Status__c = 'To Do',
          Sync_Status__c = 'Pending'
        ),
        statusOnly()
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

  // ---------- logging ----------

  @IsTest
  static void buffersOneLogPerCalloutAndClearsOnDrain() {
    Test.setMock(
      HttpCalloutMock.class,
      new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK)
    );
    JiraAdapter adapter = new JiraAdapter();

    Test.startTest();
    adapter.push(workItem('In Progress', 'Pending'), statusOnly());
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
    adapter.push(workItem('In Progress', 'Pending'), statusOnly());
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

  // ---------- created, dates and description (build 08) ----------

  private static void mapStartDateTo(String jiraFieldId) {
    FieldMappingService.reset();
    FieldMappingService.injected = new List<Field_Mapping__mdt>{
      new Field_Mapping__mdt(
        External_System__c = ExternalSystem.JIRA,
        Mapping_Type__c = FieldMappingService.FIELD,
        External_Value__c = jiraFieldId,
        External_Label__c = 'Start date',
        Normalized_Value__c = 'Start_Date__c',
        Is_Active__c = true
      )
    };
  }

  private static final Datetime UPDATED = Datetime.newInstanceGmt(
    2026,
    9,
    20,
    10,
    0,
    0
  );

  @IsTest
  static void readsCreatedDueStartAndDescription() {
    mapStartDateTo('customfield_10015');
    String payload = JiraWebhookPayloadFactory.issueUpdatedWithFields(
      '10039',
      'DOPP-15',
      'In Progress',
      UPDATED,
      new Map<String, Object>{
        // The site's own offset, late in the evening: the UTC instant is the next day.
        'created' => '2026-09-12T21:18:24.000-0700',
        'duedate' => '2026-09-30',
        'customfield_10015' => '2026-09-21',
        'description' => 'Board cards grouped by status.'
      }
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 9, 13, 4, 18, 24),
      change.sourceCreated,
      'fields.created, through the same offset handling as fields.updated (DOPP-20).'
    );
    Assert.isTrue(change.carriesDueDate);
    Assert.areEqual(Date.newInstance(2026, 9, 30), change.dueDate);
    Assert.isTrue(change.carriesStartDate);
    Assert.areEqual(Date.newInstance(2026, 9, 21), change.startDate);
    Assert.isTrue(change.carriesDescription);
    Assert.areEqual('Board cards grouped by status.', change.description);
  }

  @IsTest
  static void aDeliveryWithNoDatesCarriesThemAsEmpty() {
    mapStartDateTo('customfield_10015');
    // What Jira actually sends for an issue with no dates and no description: every key, null.
    String payload = JiraWebhookPayloadFactory.issueUpdatedWithFields(
      '10039',
      'DOPP-15',
      'In Progress',
      UPDATED,
      new Map<String, Object>{
        'duedate' => null,
        'customfield_10015' => null,
        'description' => null
      }
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    Assert.isTrue(
      change.carriesDueDate,
      'A key present with a null value is Jira saying "none" - it has to clear a due date ' +
      'Salesforce holds, or a date removed in Jira would stay on the board forever.'
    );
    Assert.isNull(change.dueDate);
    Assert.isTrue(change.carriesStartDate);
    Assert.isNull(change.startDate);
    Assert.isTrue(change.carriesDescription);
    Assert.isNull(change.description);
    Assert.isNull(
      change.sourceCreated,
      'No created in the payload: not carried.'
    );
  }

  @IsTest
  static void aPayloadWithoutTheKeysCarriesNoneOfThem() {
    mapStartDateTo('customfield_10015');
    String payload = JiraWebhookPayloadFactory.issueUpdated(
      '10039',
      'DOPP-15',
      'In Progress',
      UPDATED
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    Assert.isFalse(change.carriesDueDate, 'Absent is not carried.');
    Assert.isFalse(change.carriesStartDate);
    Assert.isFalse(change.carriesDescription);
  }

  @IsTest
  static void theStartDateFieldIdIsReadFromConfiguration() {
    // A different Jira site with a different custom field id. Nothing but the mapping row
    // changes, which is the whole point of it being configuration.
    mapStartDateTo('customfield_99999');
    String payload = JiraWebhookPayloadFactory.issueUpdatedWithFields(
      '10039',
      'DOPP-15',
      'In Progress',
      UPDATED,
      new Map<String, Object>{
        'customfield_10015' => '2026-01-01',
        'customfield_99999' => '2026-10-01'
      }
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.areEqual('customfield_99999', JiraAdapter.startDateFieldId());
    Assert.areEqual(
      Date.newInstance(2026, 10, 1),
      change.startDate,
      'The configured field is read, and this site\'s customfield_10015 is just another field.'
    );
  }

  @IsTest
  static void withNoStartDateFieldConfiguredNoStartDateIsRead() {
    FieldMappingService.reset();
    FieldMappingService.injected = new List<Field_Mapping__mdt>();
    String payload = JiraWebhookPayloadFactory.issueUpdatedWithFields(
      '10039',
      'DOPP-15',
      'In Progress',
      UPDATED,
      new Map<String, Object>{ 'customfield_10015' => '2026-09-21' }
    );

    InboundChange change = parseOne(new JiraAdapter(), payload);

    Assert.isNull(JiraAdapter.startDateFieldId());
    Assert.isFalse(
      change.carriesStartDate,
      'No constant stands in for a missing mapping row.'
    );
  }

  @IsTest
  static void anUnreadableDateIsNotAppliedAndSaysSo() {
    mapStartDateTo('customfield_10015');
    JiraAdapter adapter = new JiraAdapter();
    String payload = JiraWebhookPayloadFactory.issueUpdatedWithFields(
      '10039',
      'DOPP-15',
      'In Progress',
      UPDATED,
      new Map<String, Object>{
        'duedate' => '30/09/2026',
        'customfield_10015' => '2026-09-21'
      }
    );

    InboundChange change = parseOne(adapter, payload);

    Assert.isTrue(
      change.isUsable(),
      'One unreadable field does not cost the delivery its status change.'
    );
    Assert.isFalse(
      change.carriesDueDate,
      'Not carried rather than carried as empty: clearing a date Salesforce holds on the ' +
      'strength of a value nobody could read would be worse than leaving it.'
    );
    Assert.isTrue(change.carriesStartDate, 'The readable field still applies.');
    List<Integration_Log__c> logs = adapter.drainLogs();
    Assert.areEqual(1, logs.size());
    Assert.isTrue(
      logs[0].Error_Message__c.contains('duedate') &&
      logs[0].Error_Message__c.contains('30/09/2026'),
      logs[0].Error_Message__c
    );
  }

  @IsTest
  static void aDocumentShapedDescriptionIsReadAsText() {
    // REST v3's Atlassian Document Format. Webhooks send v2's plain string today; this is the
    // insurance against that changing, so the description does not quietly stop syncing.
    Object adf = JSON.deserializeUntyped(
      '{"type":"doc","version":1,"content":[' +
        '{"type":"paragraph","content":[{"type":"text","text":"First "},' +
        '{"type":"text","text":"line","marks":[{"type":"strong"}]}]},' +
        '{"type":"bulletList","content":[' +
        '{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]}]},' +
        '{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"two"}]}]}' +
        ']}]}'
    );

    Assert.areEqual('First line\none\ntwo', JiraAdapter.plainText(adf));
    Assert.areEqual('As sent', JiraAdapter.plainText('As sent'));
    Assert.isNull(JiraAdapter.plainText(null));
  }

  // ---------- pushing fields (build 08) ----------

  private static Work_Item__c editedItem() {
    Work_Item__c item = workItem('In Progress', 'Pending');
    item.Title__c = 'Render work items on the board';
    item.Due_Date__c = Date.newInstance(2026, 9, 3);
    item.Start_Date__c = Date.newInstance(2026, 9, 1);
    return item;
  }

  private static JiraCalloutMock mockFor(JiraCalloutMock.Scenario scenario) {
    JiraCalloutMock mock = new JiraCalloutMock(scenario);
    Test.setMock(HttpCalloutMock.class, mock);
    return mock;
  }

  @IsTest
  static void aTitleEditIsOnePutCarryingOnlyTheSummary() {
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(editedItem(), new Set<SyncField>{ SyncField.TITLE });
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Assert.areEqual(1, mock.callCount(), 'One PUT, no transition calls.');
    Assert.areEqual('PUT', mock.captured[0].method);
    Assert.areEqual(
      'callout:Jira_Classic/rest/api/3/issue/10023',
      mock.captured[0].endpoint,
      'The issue itself, by its raw id.'
    );
    Assert.areEqual(
      '{"fields":{"summary":"Render work items on the board"}}',
      mock.captured[0].body,
      'Only the field that changed. Sending the unchanged due date too would overwrite one ' +
      'somebody may have just changed in Jira.'
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      result.confirmedFields
    );
  }

  @IsTest
  static void datesTravelAsCalendarDaysAndAClearedOneAsNull() {
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);
    Work_Item__c item = editedItem();
    item.Start_Date__c = null;
    // The start date field comes from configuration, never a constant.
    FieldMappingService.reset();
    FieldMappingService.injected = new List<Field_Mapping__mdt>{
      new Field_Mapping__mdt(
        External_System__c = ExternalSystem.JIRA,
        Mapping_Type__c = FieldMappingService.FIELD,
        External_Value__c = 'customfield_99999',
        Normalized_Value__c = 'Start_Date__c',
        Is_Active__c = true
      )
    };

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(
        item,
        new Set<SyncField>{ SyncField.DUE_DATE, SyncField.START_DATE }
      );
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Map<String, Object> fields = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        mock.captured[0].body
      ))
      .get('fields');
    Assert.areEqual(
      new Set<String>{ 'duedate', 'customfield_99999' },
      fields.keySet(),
      'Exactly the two fields, the start date under the configured id.'
    );
    Assert.areEqual(
      '2026-09-03',
      fields.get('duedate'),
      'A calendar day, never a timestamp.'
    );
    Assert.isNull(
      fields.get('customfield_99999'),
      'A cleared start date is an explicit null, which is how Jira removes one.'
    );
  }

  @IsTest
  static void withNoStartDateFieldMappedTheStartDateIsRefusedWithoutACallout() {
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);
    FieldMappingService.reset();
    FieldMappingService.injected = new List<Field_Mapping__mdt>();

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(editedItem(), new Set<SyncField>{ SyncField.START_DATE });
    Test.stopTest();

    Assert.areEqual(SyncResult.Outcome.BAD_REQUEST, result.outcome);
    Assert.isTrue(
      result.message.contains('Field_Mapping__mdt'),
      'Says what to add: ' + result.message
    );
    Assert.areEqual(0, mock.callCount(), 'No constant stands in for it.');
    Assert.isTrue(result.confirmedFields.isEmpty());
  }

  @IsTest
  static void anEditAndAStatusChangeAreThreeCallsAndBothConfirmed() {
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(
        editedItem(),
        new Set<SyncField>{ SyncField.TITLE, SyncField.STATUS }
      );
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Assert.areEqual(3, mock.callCount(), 'The most one item ever costs.');
    Assert.areEqual(
      'PUT',
      mock.captured[0].method,
      'The edit goes first: some workflows make a Done issue read-only.'
    );
    Assert.areEqual('GET', mock.captured[1].method);
    Assert.areEqual('POST', mock.captured[2].method);
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE, SyncField.STATUS },
      result.confirmedFields
    );
  }

  @IsTest
  static void aRefusedTransitionStillLandsTheTitle() {
    mockFor(JiraCalloutMock.Scenario.NO_MATCHING_TRANSITION);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(
        editedItem(),
        new Set<SyncField>{ SyncField.TITLE, SyncField.STATUS }
      );
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
      result.outcome,
      'The refused half decides the outcome.'
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      result.confirmedFields,
      'And the half that landed is reported, so it is not pushed again and the refused half ' +
      'is not marked as synced.'
    );
    Assert.isTrue(
      result.message.contains('Available: Done'),
      'The reason says what Jira would accept: ' + result.message
    );
  }

  @IsTest
  static void aRefusedEditStillLandsTheStatus() {
    mockFor(JiraCalloutMock.Scenario.PUT_REFUSED);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(
        editedItem(),
        new Set<SyncField>{ SyncField.TITLE, SyncField.STATUS }
      );
    Test.stopTest();

    Assert.areEqual(SyncResult.Outcome.REMOTE_ERROR, result.outcome);
    Assert.areEqual(400, result.statusCode);
    Assert.areEqual(
      new Set<SyncField>{ SyncField.STATUS },
      result.confirmedFields
    );
    Assert.isTrue(
      result.message.contains('summary'),
      'Names the field Jira refused: ' + result.message
    );
  }

  @IsTest
  static void movingBackToWhereJiraAlreadyIsCountsAsDone() {
    // The way out of a refused move: put the card back in the column Jira never left. No
    // transition lands on a status the issue is already in, so without the extra read this
    // would be refused too, and the card could never be set right from Salesforce.
    JiraCalloutMock mock = mockFor(
      JiraCalloutMock.Scenario.NO_MATCHING_TRANSITION
    );
    mock.currentStatus = 'In Progress';

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(workItem('In Progress', 'Failed'), statusOnly());
    Test.stopTest();

    Assert.areEqual(
      SyncResult.Outcome.ALREADY_IN_TARGET_STATUS,
      result.outcome
    );
    Assert.isTrue(result.isSuccess());
    Assert.areEqual(
      new Set<SyncField>{ SyncField.STATUS },
      result.confirmedFields
    );
    Assert.areEqual(2, mock.callCount(), 'Two reads, and no POST.');
    Assert.isTrue(
      mock.captured[1].endpoint.endsWith('/issue/10023?fields=status'),
      mock.captured[1].endpoint
    );
  }

  @IsTest
  static void pushingNothingCallsNothing() {
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(editedItem(), new Set<SyncField>());
    Test.stopTest();

    Assert.areEqual(SyncResult.Outcome.NOTHING_TO_PUSH, result.outcome);
    Assert.areEqual(0, mock.callCount());
  }

  // ---------- priority, inbound (build 09) ----------

  private static void mapJiraPriorities() {
    FieldMappingService.reset();
    FieldMappingService.injected = JiraWebhookPayloadFactory.priorityMappings();
  }

  private static String withPriority(Object priority) {
    return JiraWebhookPayloadFactory.issueUpdatedWithFields(
      '10039',
      'DOPP-15',
      'In Progress',
      UPDATED,
      new Map<String, Object>{
        'priority' => priority,
        'duedate' => '2026-09-30'
      }
    );
  }

  @IsTest
  static void eachPriorityIsReadByItsId() {
    mapJiraPriorities();
    Map<String, String> expected = new Map<String, String>{
      '2' => 'High',
      '3' => 'Medium',
      '4' => 'Low'
    };

    for (String id : expected.keySet()) {
      // The name is deliberately wrong: the id is what is read, never the name (decision 2).
      InboundChange change = parseOne(
        new JiraAdapter(),
        withPriority(JiraWebhookPayloadFactory.priority(id, 'Renamed in Jira'))
      );
      Assert.isTrue(change.carriesPriority, 'Priority ' + id + ' is carried.');
      Assert.areEqual(expected.get(id), change.priority, 'Priority ' + id);
    }
  }

  @IsTest
  static void theEnDashIsNoPriority() {
    mapJiraPriorities();

    InboundChange change = parseOne(
      new JiraAdapter(),
      withPriority(JiraWebhookPayloadFactory.priority('10000', '\u2013'))
    );

    Assert.isTrue(
      change.carriesPriority,
      'Choosing the en dash in Jira is choosing none, and has to clear the priority here.'
    );
    Assert.isNull(change.priority, 'Blank, not a sentinel (decision 1).');
  }

  @IsTest
  static void anExplicitNullPriorityIsNoPriorityToo() {
    mapJiraPriorities();

    InboundChange change = parseOne(new JiraAdapter(), withPriority(null));

    Assert.isTrue(change.carriesPriority, 'Jira saying the issue has none.');
    Assert.isNull(change.priority);
  }

  @IsTest
  static void aPayloadWithoutPriorityDoesNotCarryIt() {
    mapJiraPriorities();

    InboundChange change = parseOne(
      new JiraAdapter(),
      JiraWebhookPayloadFactory.issueUpdated(
        '10039',
        'DOPP-15',
        'In Progress',
        UPDATED
      )
    );

    Assert.isFalse(
      change.carriesPriority,
      'Absent is not none: a delivery that does not mention priority leaves it alone.'
    );
  }

  @IsTest
  static void anUnknownPriorityIsNotCarriedAndIsLogged() {
    mapJiraPriorities();
    JiraAdapter adapter = new JiraAdapter();

    // Highest: out of DOPP's scheme, still on the site, and mapped by no row.
    InboundChange change = parseOne(
      adapter,
      withPriority(JiraWebhookPayloadFactory.priority('1', 'Highest'))
    );

    Assert.isTrue(
      change.isUsable(),
      'An unknown priority never fails the delivery (decision 4).'
    );
    Assert.isFalse(
      change.carriesPriority,
      'Not carried, so the processor leaves the field as it was. Carried as blank would clear ' +
      'a priority the owner never removed.'
    );
    Assert.isTrue(
      change.carriesDueDate,
      'The rest of the change still applies.'
    );
    List<Integration_Log__c> logs = adapter.drainLogs();
    Assert.areEqual(1, logs.size(), 'One warning.');
    Assert.isTrue(
      logs[0].Error_Message__c.contains('priority 1 ') &&
        logs[0].Error_Message__c.contains('Highest') &&
        logs[0].Error_Message__c.contains('DOPP-15'),
      'The warning names the id, what Jira calls it, and the issue: ' +
      logs[0].Error_Message__c
    );
    Assert.areEqual(LogDirection.INBOUND, logs[0].Direction__c);
  }

  @IsTest
  static void aPriorityWithNoIdIsAbsent() {
    mapJiraPriorities();
    JiraAdapter adapter = new JiraAdapter();

    InboundChange change = parseOne(
      adapter,
      withPriority(new Map<String, Object>{ 'name' => 'High' })
    );

    Assert.isFalse(
      change.carriesPriority,
      'Malformed counts as absent, as a nameless issuetype does - never as none.'
    );
    Assert.areEqual(0, adapter.drainLogs().size());
  }

  // ---------- priority, outbound (build 09) ----------

  @IsTest
  static void aPriorityOnlySaveSendsOnlyThePriorityById() {
    mapJiraPriorities();
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);
    // Blank last: none in Salesforce goes out as the en dash (decision 1).
    Map<String, String> idByValue = new Map<String, String>{
      'High' => '2',
      'Medium' => '3',
      'Low' => '4',
      null => '10000'
    };
    List<String> order = new List<String>{ 'High', 'Medium', 'Low', null };

    Test.startTest();
    List<SyncResult> results = new List<SyncResult>();
    for (String value : order) {
      Work_Item__c item = editedItem();
      item.Priority__c = value;
      results.add(
        new JiraAdapter().push(item, new Set<SyncField>{ SyncField.PRIORITY })
      );
    }
    Test.stopTest();

    Assert.areEqual(4, mock.callCount(), 'One PUT per push, and nothing else.');
    for (Integer i = 0; i < order.size(); i++) {
      Assert.isTrue(results[i].isSuccess(), 'Failure: ' + results[i].message);
      Assert.areEqual('PUT', mock.captured[i].method);
      Assert.areEqual(
        '{"fields":{"priority":{"id":"' + idByValue.get(order[i]) + '"}}}',
        mock.captured[i].body,
        'Only the priority, by id, for ' + order[i]
      );
      Assert.areEqual(
        new Set<SyncField>{ SyncField.PRIORITY },
        results[i].confirmedFields
      );
    }
  }

  @IsTest
  static void aTitleAndPrioritySaveIsOnePutCarryingBoth() {
    mapJiraPriorities();
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);
    Work_Item__c item = editedItem();
    item.Priority__c = 'High';

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(item, new Set<SyncField>{ SyncField.TITLE, SyncField.PRIORITY });
    Test.stopTest();

    Assert.isTrue(result.isSuccess(), 'Failure: ' + result.message);
    Assert.areEqual(1, mock.callCount(), 'One PUT.');
    Map<String, Object> fields = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        mock.captured[0].body
      ))
      .get('fields');
    Assert.areEqual(new Set<String>{ 'summary', 'priority' }, fields.keySet());
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE, SyncField.PRIORITY },
      result.confirmedFields
    );
  }

  @IsTest
  static void aPriorityWithNoMappingIsRefusedWhileTheRestStillGoes() {
    FieldMappingService.reset();
    FieldMappingService.injected = new List<Field_Mapping__mdt>();
    JiraCalloutMock mock = mockFor(JiraCalloutMock.Scenario.TRANSITION_OK);
    Work_Item__c item = editedItem();
    item.Priority__c = 'High';

    Test.startTest();
    SyncResult result = new JiraAdapter()
      .push(item, new Set<SyncField>{ SyncField.TITLE, SyncField.PRIORITY });
    Test.stopTest();

    Assert.areEqual(SyncResult.Outcome.BAD_REQUEST, result.outcome);
    Assert.isTrue(
      result.message.contains('type Priority'),
      'Says what to add: ' + result.message
    );
    Assert.areEqual(
      '{"fields":{"summary":"Render work items on the board"}}',
      mock.captured[0].body,
      'The title still goes, alone - an unmapped priority is never guessed.'
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      result.confirmedFields,
      'So the priority stays pending, with the reason.'
    );
  }
}
