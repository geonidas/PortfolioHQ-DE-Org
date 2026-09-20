/**
 * Endpoint behaviour: the handshake, the delivery, and what each answer tells Asana to do next.
 *
 * Asana reads status codes as instructions. A non-2xx is a request to retry, so it is reserved
 * for failures where retrying would help; a delivery it should never send again gets a 200.
 * Speed matters too - a response slower than ten seconds counts as a failure, and a webhook is
 * deleted after twenty-four hours of them - so the callout assertions here are not decoration.
 */
@IsTest
private class AsanaWebhookResourceTest {
  private static final String RESOURCE_GID = '1211234567890';

  private static String randomSecret() {
    return EncodingUtil.convertToHex(Crypto.generateAesKey(256));
  }

  /**
   * Asana signs with a bare lowercase hex HMAC-SHA256, with no algorithm prefix. WebhookSignature
   * tolerates both spellings, so the helper deliberately sends the bare one - signing with the
   * prefixed form would test a shape Asana never sends.
   */
  private static String sign(String body, String secret) {
    return EncodingUtil.convertToHex(
      Crypto.generateMac('hmacSHA256', Blob.valueOf(body), Blob.valueOf(secret))
    );
  }

  private static String post(
    String resourceId,
    String body,
    String secretHeader,
    String signatureHeader
  ) {
    RestRequest request = new RestRequest();
    request.requestUri =
      '/services/apexrest/v1/webhook/asana/' +
      (resourceId == null ? '' : resourceId);
    request.httpMethod = 'POST';
    request.requestBody = body == null ? null : Blob.valueOf(body);
    if (secretHeader != null) {
      request.addHeader('X-Hook-Secret', secretHeader);
    }
    if (signatureHeader != null) {
      request.addHeader('X-Hook-Signature', signatureHeader);
    }
    RestContext.request = request;
    RestContext.response = new RestResponse();
    AsanaWebhookResource.receive();
    return RestContext.response.responseBody == null
      ? null
      : RestContext.response.responseBody.toString();
  }

  /** A delivery body with `count` events. */
  private static String eventsBody(Integer count) {
    List<String> events = new List<String>();
    for (Integer i = 0; i < count; i++) {
      events.add(
        '{"action":"changed","resource":{"gid":"11' +
          i +
          '","resource_type":"task"},"created_at":"2026-09-19T10:00:0' +
          Math.mod(i, 10) +
          '.000Z"}'
      );
    }
    return '{"events":[' + String.join(events, ',') + ']}';
  }

  /**
   * Deliveries accepted for processing, which is what Signature_Valid__c means on this object.
   *
   * Deliberately not filtered on Processing_Status__c. Inserting a Pending row publishes a
   * platform event, and the subscriber runs at Test.stopTest - so by the time a test looks, the
   * rows it staged have already been picked up and moved off Pending. That is the pipeline
   * working, not a staging failure, and filtering on Pending measured it as zero.
   */
  private static List<Webhook_Event__c> staged() {
    return [
      SELECT Raw_Payload__c, Source_System__c, Signature_Valid__c
      FROM Webhook_Event__c
      WHERE Signature_Valid__c = TRUE
    ];
  }

  // ---------- the handshake ----------

  @IsTest
  static void aHandshakeStagesTheSecretAndEchoesTheHeaderExactly() {
    String offered = randomSecret();

    Test.startTest();
    String body = post(RESOURCE_GID, '{}', offered, null);
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'Asana only completes the registration on a 2xx.'
    );
    Assert.areEqual(
      offered,
      RestContext.response.headers.get('X-Hook-Secret'),
      'Echoed byte for byte. Matching the header is the entire test Asana performs, and a ' +
      'value re-encoded or trimmed into a different string fails it.'
    );
    Assert.isTrue(body.contains('handshake'), 'Body says so: ' + body);
    Assert.areEqual(
      offered,
      [
        SELECT Secret__c
        FROM Webhook_Secret__c
        WHERE Resource_Id__c = :RESOURCE_GID
      ]
      .Secret__c,
      'And the secret is staged before the response is built - a 200 whose secret was never ' +
      'recorded registers a webhook that can never be verified.'
    );
    Assert.areEqual(
      0,
      staged().size(),
      'A handshake is not a delivery. Nothing was staged for processing.'
    );
  }

  @IsTest
  static void aHandshakeNeverReadsTheBody() {
    String offered = randomSecret();

    Test.startTest();
    // Asana's handshake carries no meaningful body. Something unparseable proves the endpoint
    // branches on the header and never looks past it.
    post(RESOURCE_GID, 'this is not json at all', offered, null);
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'The body is irrelevant to a handshake, so an unreadable one changes nothing.'
    );
    Assert.areEqual(
      offered,
      RestContext.response.headers.get('X-Hook-Secret'),
      'And the header still comes back.'
    );
  }

  @IsTest
  static void aHandshakeWithNoResourceGidIsRefused() {
    Test.startTest();
    post(null, '{}', randomSecret(), null);
    Test.stopTest();

    Assert.areEqual(
      400,
      RestContext.response.statusCode,
      'Without a resource gid in the target URL there is nothing to key the secret on, and ' +
      'every later delivery would be unverifiable.'
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Webhook_Secret__c]);
  }

  @IsTest
  static void aSecondHandshakeForTheSameResourceIsRefused() {
    String genuine = randomSecret();
    post(RESOURCE_GID, '{}', genuine, null);

    Test.startTest();
    post(RESOURCE_GID, '{}', 'an-attackers-secret', null);
    Test.stopTest();

    Assert.areEqual(
      409,
      RestContext.response.statusCode,
      'This endpoint is unauthenticated. Replacing a live secret would let the caller sign ' +
      'whatever they liked afterwards, so a resource already registered is never re-keyed here.'
    );
    Assert.areEqual(
      genuine,
      [
        SELECT Secret__c
        FROM Webhook_Secret__c
        WHERE Resource_Id__c = :RESOURCE_GID
      ]
      .Secret__c,
      'And the genuine secret is untouched.'
    );
  }

  // ---------- deliveries ----------

  @IsTest
  static void aSignedDeliveryStagesOneRowPerEvent() {
    String secret = randomSecret();
    WebhookSecretStore.injectedSecrets = new Map<String, String>{
      WebhookSecretStore.developerNameFor(RESOURCE_GID) => secret
    };
    String body = eventsBody(3);

    Test.startTest();
    String answer = post(RESOURCE_GID, body, null, sign(body, secret));
    Test.stopTest();

    Assert.areEqual(200, RestContext.response.statusCode);
    Assert.isTrue(answer.contains('accepted'), answer);

    List<Webhook_Event__c> rows = staged();
    Assert.areEqual(
      3,
      rows.size(),
      'One row per event. Asana batches many events into one delivery, and the processor ' +
      'model is one delivery, one change.'
    );
    for (Webhook_Event__c row : rows) {
      Assert.areEqual('Asana', row.Source_System__c);
      Assert.isTrue(
        row.Raw_Payload__c.contains('"action":"changed"'),
        'Each element is stored verbatim for the adapter: ' + row.Raw_Payload__c
      );
      Assert.isFalse(
        row.Raw_Payload__c.contains('"events"'),
        'And the envelope is not stored with it.'
      );
    }
  }

  @IsTest
  static void theSignatureIsComputedOverTheRawBytes() {
    // The failure this guards against is silent: deserialising and re-serialising a payload
    // changes whitespace and key order, which changes the digest, which fails every signature.
    String secret = randomSecret();
    WebhookSecretStore.injectedSecrets = new Map<String, String>{
      WebhookSecretStore.developerNameFor(RESOURCE_GID) => secret
    };
    String body =
      '{\n  "events" : [\n    {  "action" : "changed" ,\n' +
      '  "resource" : { "gid" : "119" }  }\n  ]\n}\n';

    Test.startTest();
    post(RESOURCE_GID, body, null, sign(body, secret));
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'A body full of unusual whitespace still verifies, because the MAC is taken over the ' +
      'bytes as received and never over a reserialised parse.'
    );
    Assert.areEqual(1, staged().size(), 'And its one event is staged.');
  }

  @IsTest
  static void aWrongSignatureIsRejectedAndStagesNothing() {
    String secret = randomSecret();
    WebhookSecretStore.injectedSecrets = new Map<String, String>{
      WebhookSecretStore.developerNameFor(RESOURCE_GID) => secret
    };
    String body = eventsBody(2);

    Test.startTest();
    post(RESOURCE_GID, body, null, sign(body, 'not the right secret'));
    Test.stopTest();

    Assert.areEqual(
      401,
      RestContext.response.statusCode,
      'An invalid signature is never retried into acceptance.'
    );
    Assert.areEqual(0, staged().size(), 'Nothing was staged for processing.');

    List<Webhook_Event__c> rejections = [
      SELECT Error_Message__c, Raw_Payload__c, Signature_Valid__c
      FROM Webhook_Event__c
    ];
    Assert.areEqual(1, rejections.size(), 'One row records the rejection.');
    Assert.isFalse(rejections[0].Signature_Valid__c);
    Assert.isNull(
      rejections[0].Raw_Payload__c,
      'An unverified body is never stored - anyone who finds this URL can POST to it.'
    );
    Assert.isTrue(
      rejections[0].Error_Message__c.contains('sha256='),
      'A digest prefix is kept so repeat attempts are recognisable: ' +
      rejections[0].Error_Message__c
    );
  }

  @IsTest
  static void aDeliveryForAnUnregisteredResourceIsRejectedNotThrown() {
    WebhookSecretStore.injectedSecrets = new Map<String, String>();
    String body = eventsBody(1);

    Test.startTest();
    post('9999999999', body, null, sign(body, randomSecret()));
    Test.stopTest();

    Assert.areEqual(
      401,
      RestContext.response.statusCode,
      'Same answer as a wrong signature. A caller must not be able to tell "no such webhook" ' +
      'from "wrong key" - and it must not be able to make the endpoint throw either.'
    );
    Assert.areEqual(0, staged().size());
  }

  @IsTest
  static void neitherHeaderIsABadRequest() {
    Test.startTest();
    post(RESOURCE_GID, eventsBody(1), null, null);
    Test.stopTest();

    Assert.areEqual(
      400,
      RestContext.response.statusCode,
      'Neither a handshake nor a delivery. Nothing to retry, nothing to process.'
    );
    Assert.areEqual(0, staged().size());
    Assert.areEqual(0, [SELECT COUNT() FROM Webhook_Secret__c]);
  }

  @IsTest
  static void anEmptyEventsArrayIsAHeartbeatNotAFailure() {
    String secret = randomSecret();
    WebhookSecretStore.injectedSecrets = new Map<String, String>{
      WebhookSecretStore.developerNameFor(RESOURCE_GID) => secret
    };
    String body = '{"events":[]}';

    Test.startTest();
    post(RESOURCE_GID, body, null, sign(body, secret));
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'Asana sends an empty array periodically to check the endpoint is alive. Anything but ' +
      'a 2xx counts against the twenty-four hours before it deletes the webhook.'
    );
    Assert.areEqual(0, staged().size(), 'And there is nothing to stage.');
  }

  @IsTest
  static void aFiftyEventDeliveryStagesFiftyRowsAndCallsOutToNothing() {
    String secret = randomSecret();
    WebhookSecretStore.injectedSecrets = new Map<String, String>{
      WebhookSecretStore.developerNameFor(RESOURCE_GID) => secret
    };
    String body = eventsBody(50);

    // Both readings inside the window: Test.stopTest restores the outer limits context, so a
    // count taken after it reports the callouts made before startTest - an assertion that
    // cannot fail. Learned in step 3 by breaking one on purpose.
    Test.startTest();
    Integer calloutsBefore = Limits.getCallouts();
    Integer queriesBefore = Limits.getQueries();
    post(RESOURCE_GID, body, null, sign(body, secret));
    Integer calloutsAfter = Limits.getCallouts();
    Integer queriesAfter = Limits.getQueries();
    Test.stopTest();

    Assert.areEqual(200, RestContext.response.statusCode);
    Assert.areEqual(
      50,
      staged().size(),
      'One row per event, whatever the batch size.'
    );
    Assert.areEqual(
      calloutsBefore,
      calloutsAfter,
      'No callout in the synchronous transaction. Hydration is the adapter\'s job, in another ' +
      'transaction - Asana counts a response slower than ten seconds as a failed delivery.'
    );
    Assert.areEqual(
      queriesBefore,
      queriesAfter,
      'And no SOQL either: the secret came from Custom Metadata, which is not a query.'
    );
  }

  @IsTest
  static void aBodyThatIsNotAnEventsEnvelopeIsAcceptedAndDropped() {
    String secret = randomSecret();
    WebhookSecretStore.injectedSecrets = new Map<String, String>{
      WebhookSecretStore.developerNameFor(RESOURCE_GID) => secret
    };
    String body = 'this is not json at all';

    Test.startTest();
    post(RESOURCE_GID, body, null, sign(body, secret));
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'The signature proved who sent it, so a body we cannot read is our problem. Redelivering ' +
      'the same bytes would fail identically, so asking for a retry would be a lie.'
    );
    Assert.areEqual(0, staged().size(), 'Nothing processable was staged.');
  }

  // ---------- the gateway seam ----------

  @IsTest
  static void anUpstreamVerifiedDeliveryNeedsNoSignature() {
    // One boolean and one early return, for the build that moves verification to a gateway.
    // Both paths can then run side by side during cutover.
    AsanaWebhookResource.signatureVerifiedUpstream = true;
    WebhookSecretStore.injectedSecrets = new Map<String, String>();

    Test.startTest();
    post(RESOURCE_GID, eventsBody(2), null, null);
    Test.stopTest();

    Assert.areEqual(
      200,
      RestContext.response.statusCode,
      'With verification done upstream the endpoint trusts what reaches it.'
    );
    Assert.areEqual(2, staged().size(), 'And stages the batch as usual.');
  }

  @IsTest
  static void theUpstreamFlagIsOffUnlessSomethingTurnsItOn() {
    // The assertion that keeps the seam from becoming a hole. If this ever fails, an
    // unauthenticated caller can stage whatever it likes.
    WebhookSecretStore.injectedSecrets = new Map<String, String>();

    Test.startTest();
    post(RESOURCE_GID, eventsBody(1), null, 'deadbeef');
    Test.stopTest();

    Assert.areEqual(
      401,
      RestContext.response.statusCode,
      'Default is verify-here. A default of true would accept anything that arrived.'
    );
    Assert.areEqual(0, staged().size());
  }
}
