/**
 * Endpoint behaviour: what gets accepted, what gets rejected, and what each answer tells Jira
 * to do next.
 */
@IsTest
private class JiraWebhookResourceTest {
  private static String post(String payload, String signatureHeader) {
    RestRequest request = new RestRequest();
    request.requestUri = '/services/apexrest/v1/webhook/jira';
    request.httpMethod = 'POST';
    request.requestBody = payload == null ? null : Blob.valueOf(payload);
    if (signatureHeader != null) {
      request.addHeader('X-Hub-Signature', signatureHeader);
    }
    RestContext.request = request;
    RestContext.response = new RestResponse();
    JiraWebhookResource.receive();
    return RestContext.response.responseBody == null
      ? null
      : RestContext.response.responseBody.toString();
  }

  private static String samplePayload() {
    return JiraWebhookPayloadFactory.issueUpdated(
      '10039',
      'DOPP-15',
      'In Progress',
      System.now()
    );
  }

  /**
   * Run the processor over whatever the endpoint just staged.
   *
   * Since build 07 the subscriber ENQUEUES rather than applying inline - an adapter is allowed
   * to call out from parseInbound, and Apex refuses a callout made from a trigger. A queueable
   * enqueued while Test.stopTest delivers a platform event does not execute, so these tests
   * drive the second half themselves. The boundary is real, not a test artefact: in production
   * the same work happens in WorkItemInboundQueueable a moment later.
   */
  private static void drainStagedDeliveries() {
    WorkItemInboundProcessor.process(
      [
        SELECT
          Id,
          Source_System__c,
          Raw_Payload__c,
          Processing_Status__c,
          Signature_Valid__c
        FROM Webhook_Event__c
        WHERE
          Processing_Status__c = :DeliveryStatus.PENDING
          AND Signature_Valid__c = TRUE
      ]
    );
  }

  @IsTest
  static void acceptsAGenuineDelivery() {
    String secret = JiraWebhookPayloadFactory.randomSecret();
    IntegrationSecretService.inject(secret, true);
    String payload = samplePayload();

    Test.startTest();
    String body = post(
      payload,
      WebhookSignature.sign(Blob.valueOf(payload), secret)
    );
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'A signed delivery should be accepted.'
    );
    Assert.isTrue(body.contains('accepted'), 'Body should say so: ' + body);

    List<Webhook_Event__c> events = [
      SELECT
        Signature_Valid__c,
        Raw_Payload__c,
        Source_System__c,
        Received_At__c,
        Error_Message__c
      FROM Webhook_Event__c
    ];
    Assert.areEqual(1, events.size(), 'Exactly one row per delivery.');
    Assert.isTrue(
      events[0].Signature_Valid__c,
      'Signature should be recorded as valid.'
    );
    Assert.areEqual(
      'Jira',
      events[0].Source_System__c,
      'Source should be recorded.'
    );
    Assert.isNotNull(
      events[0].Received_At__c,
      'Receipt time should be recorded.'
    );
    Assert.areEqual(
      payload,
      events[0].Raw_Payload__c,
      'Payload must be stored byte-for-byte.'
    );
    Assert.isNull(
      events[0].Error_Message__c,
      'An accepted delivery has no error.'
    );
  }

  @IsTest
  static void acceptsALowercaseSignatureHeader() {
    String secret = JiraWebhookPayloadFactory.randomSecret();
    IntegrationSecretService.inject(secret, true);
    String payload = samplePayload();

    RestRequest request = new RestRequest();
    request.httpMethod = 'POST';
    request.requestBody = Blob.valueOf(payload);
    request.addHeader(
      'x-hub-signature',
      WebhookSignature.sign(Blob.valueOf(payload), secret)
    );
    RestContext.request = request;
    RestContext.response = new RestResponse();

    Test.startTest();
    JiraWebhookResource.receive();
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'Header casing must not decide acceptance.'
    );
  }

  @IsTest
  static void rejectsAWrongSignature() {
    IntegrationSecretService.inject(
      JiraWebhookPayloadFactory.randomSecret(),
      true
    );
    String payload = samplePayload();

    Test.startTest();
    String body = post(
      payload,
      WebhookSignature.sign(
        Blob.valueOf(payload),
        JiraWebhookPayloadFactory.randomSecret()
      )
    );
    Test.stopTest();

    Assert.areEqual(
      401,
      RestContext.response.statusCode,
      'A signature from the wrong secret is rejected.'
    );
    Assert.isTrue(body.contains('rejected'), 'Body should say so: ' + body);
  }

  @IsTest
  static void rejectsAnUnsignedRequest() {
    IntegrationSecretService.inject(
      JiraWebhookPayloadFactory.randomSecret(),
      true
    );

    Test.startTest();
    post(samplePayload(), null);
    Test.stopTest();

    Assert.areEqual(
      401,
      RestContext.response.statusCode,
      'No signature is no entry.'
    );
  }

  @IsTest
  static void recordsTheAttemptWhenItRejects() {
    IntegrationSecretService.inject(
      JiraWebhookPayloadFactory.randomSecret(),
      true
    );

    Test.startTest();
    post(samplePayload(), 'sha256=deadbeef');
    Test.stopTest();

    List<Webhook_Event__c> events = [
      SELECT
        Signature_Valid__c,
        Processing_Status__c,
        Error_Message__c,
        Raw_Payload__c
      FROM Webhook_Event__c
    ];
    Assert.areEqual(1, events.size(), 'A rejected attempt is still recorded.');
    Assert.isFalse(events[0].Signature_Valid__c, 'Recorded as invalid.');
    Assert.areEqual(
      'Failed',
      events[0].Processing_Status__c,
      'Terminal: nothing will process it.'
    );
    Assert.isNotNull(events[0].Error_Message__c, 'Reason should be recorded.');
  }

  @IsTest
  static void anUnverifiedBodyIsNeverStored() {
    // Anyone who finds this URL can POST to it. Storing what they send would hand an
    // anonymous caller a 128 KB write per request.
    IntegrationSecretService.inject(
      JiraWebhookPayloadFactory.randomSecret(),
      true
    );
    String payload = samplePayload();

    Test.startTest();
    post(payload, 'sha256=deadbeef');
    Test.stopTest();

    Webhook_Event__c event = [
      SELECT Raw_Payload__c, Error_Message__c
      FROM Webhook_Event__c
      LIMIT 1
    ];
    Assert.isNull(
      event.Raw_Payload__c,
      'An unverified body must not be persisted.'
    );
    // The fingerprint is what keeps the row useful for investigation.
    Assert.isTrue(
      event.Error_Message__c.contains('Body not stored'),
      'Should say so: ' + event.Error_Message__c
    );
    Assert.isTrue(
      event.Error_Message__c.contains('bytes=' + payload.length()),
      'Size recorded.'
    );
    Assert.isTrue(
      event.Error_Message__c.contains('sha256='),
      'Digest recorded for correlating repeats.'
    );
    Assert.isTrue(
      event.Error_Message__c.contains('deadbeef'),
      'Offered signature recorded.'
    );
  }

  @IsTest
  static void identicalRejectedBodiesShareADigest() {
    // Two floods of the same body are recognisable as one campaign without storing either.
    IntegrationSecretService.inject(
      JiraWebhookPayloadFactory.randomSecret(),
      true
    );
    String payload = samplePayload();

    Test.startTest();
    post(payload, 'sha256=deadbeef');
    post(payload, 'sha256=deadbeef');
    post('{"different":true}', 'sha256=deadbeef');
    Test.stopTest();

    Set<String> digests = new Set<String>();
    for (Webhook_Event__c event : [
      SELECT Error_Message__c
      FROM Webhook_Event__c
    ]) {
      digests.add(
        event.Error_Message__c.substringAfter('sha256=').substringBefore(' ')
      );
    }
    Assert.areEqual(
      2,
      digests.size(),
      'Two distinct bodies should yield two distinct digests.'
    );
  }

  @IsTest
  static void averifiedBodyIsStillStoredInFull() {
    // The restriction applies to unverified traffic only - processing needs the real body.
    String secret = JiraWebhookPayloadFactory.randomSecret();
    IntegrationSecretService.inject(secret, true);
    String payload = samplePayload();

    Test.startTest();
    post(payload, WebhookSignature.sign(Blob.valueOf(payload), secret));
    Test.stopTest();

    Assert.areEqual(
      payload,
      [SELECT Raw_Payload__c FROM Webhook_Event__c LIMIT 1].Raw_Payload__c,
      'A verified body must still be stored byte-for-byte.'
    );
  }

  @IsTest
  static void anUnconfiguredOrgRejectsEverything() {
    // Simulate the unconfigured org rather than relying on this org being unconfigured.
    // Without the injection this passed for the wrong reason - a random secret simply not
    // matching whatever the org had - which is not the thing under test.
    IntegrationSecretService.injectNoRecord();
    String payload = samplePayload();

    Test.startTest();
    post(
      payload,
      WebhookSignature.sign(
        Blob.valueOf(payload),
        JiraWebhookPayloadFactory.randomSecret()
      )
    );
    Test.stopTest();

    Assert.areEqual(
      401,
      RestContext.response.statusCode,
      'With no secret configured, nothing is accepted.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Work_Item__c],
      'And nothing downstream happens.'
    );
  }

  @IsTest
  static void anInactiveSecretRejectsEverything() {
    String secret = JiraWebhookPayloadFactory.randomSecret();
    IntegrationSecretService.inject(secret, false);
    String payload = samplePayload();

    Test.startTest();
    post(payload, WebhookSignature.sign(Blob.valueOf(payload), secret));
    Test.stopTest();

    Assert.areEqual(
      401,
      RestContext.response.statusCode,
      'A correct signature against an inactive secret is still no.'
    );
  }

  @IsTest
  static void rejectionsAreIndistinguishableFromEachOther() {
    // A caller must not be able to probe whether this org has a secret configured.
    String payload = samplePayload();
    IntegrationSecretService.inject(
      JiraWebhookPayloadFactory.randomSecret(),
      true
    );
    String wrongSignature = post(payload, 'sha256=deadbeef');
    Integer wrongCode = RestContext.response.statusCode;

    IntegrationSecretService.inject(null, false);
    String unconfigured = post(payload, 'sha256=deadbeef');
    Integer unconfiguredCode = RestContext.response.statusCode;

    Assert.areEqual(
      wrongCode,
      unconfiguredCode,
      'Both rejections must use the same status.'
    );
    Assert.areEqual(wrongSignature, unconfigured, 'And the same body.');
  }

  @IsTest
  static void acceptsMalformedJsonThatCarriesAValidSignature() {
    // Signature valid, body nonsense. The endpoint does not parse, so it accepts; the
    // processor is where malformed JSON is caught. Returning 200 here is deliberate -
    // a 4xx would make Jira retry a payload that will never parse.
    String secret = JiraWebhookPayloadFactory.randomSecret();
    IntegrationSecretService.inject(secret, true);
    String junk = 'this is not json';

    Test.startTest();
    post(junk, WebhookSignature.sign(Blob.valueOf(junk), secret));
    Test.stopTest();
    drainStagedDeliveries();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'The endpoint validates signatures, not schemas.'
    );
    Assert.areEqual(
      'Failed',
      [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1]
      .Processing_Status__c,
      'The processor should have picked it up and failed it.'
    );
  }

  @IsTest
  static void endToEndDeliveryUpdatesTheWorkItem() {
    // Endpoint -> Webhook_Event__c -> platform event -> processor -> Work_Item__c.
    Project__c project = TestDataFactory.createProjects(1, true)[0];
    Work_Item__c item = TestDataFactory.createWorkItems(
      1,
      project.Id,
      false
    )[0];
    item.External_Id__c = 'jira:10039';
    item.Status__c = 'To Do';
    item.Sync_Status__c = 'Pending';
    insert item;

    String secret = JiraWebhookPayloadFactory.randomSecret();
    IntegrationSecretService.inject(secret, true);
    String payload = JiraWebhookPayloadFactory.issueUpdated(
      '10039',
      'DOPP-15',
      'In Progress',
      System.now().addMinutes(5)
    );

    Test.startTest();
    post(payload, WebhookSignature.sign(Blob.valueOf(payload), secret));
    Test.stopTest(); // delivers the platform event, which enqueues the processor
    drainStagedDeliveries();

    Work_Item__c updated = [
      SELECT Status__c, Sync_Status__c, Remote_Last_Modified__c
      FROM Work_Item__c
      WHERE Id = :item.Id
    ];
    Assert.areEqual(
      'In Progress',
      updated.Status__c,
      'Jira status should have been applied.'
    );
    Assert.areEqual(
      'Synced',
      updated.Sync_Status__c,
      'Salesforce now agrees with Jira.'
    );
    Assert.isNotNull(
      updated.Remote_Last_Modified__c,
      'Ordering timestamp should be stamped.'
    );
    Assert.areEqual(
      'Processed',
      [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1]
      .Processing_Status__c,
      'The event should have reached a terminal success state.'
    );
  }
}
