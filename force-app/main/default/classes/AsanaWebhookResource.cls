/**
 * Inbound Asana webhook endpoint, reachable by the site guest user.
 *
 * A vendor-specific REST resource is one of the few places a vendor name is allowed to appear,
 * and it has to be its own class rather than a mode on the Jira one: the two exchanges are not
 * the same shape. Jira's endpoint only ever verifies and stores. Asana's registration is a
 * two-party handshake, so this endpoint answers two different request shapes on one URL.
 *
 * The webhook's own identity comes from the URL, not from the body. Asana's handshake request
 * carries no meaningful body at all, and its delivery bodies name the resources that changed
 * rather than the webhook that noticed - so neither can say which secret to verify against. The
 * resource gid is therefore the last path segment, fixed when the webhook is registered:
 *
 *   target = <site>/services/apexrest/v1/webhook/asana/<resource_gid>
 *
 * Two shapes, decided by which header is present:
 *
 *   X-Hook-Secret    the handshake. Stage the secret, echo the header back exactly, 200.
 *                    Asana's POST /webhooks call is still in flight waiting for this.
 *   X-Hook-Signature a delivery. Verify over the raw bytes, then stage one row per event.
 *   neither          400. Nothing is staged for processing.
 *
 * Speed is a requirement, not a nicety: Asana counts a response slower than 10 seconds as a
 * failed delivery and deletes a webhook after 24 hours of consecutive failures. So this does
 * nothing synchronous beyond staging - no callouts, no business logic, no reads of Work_Item__c.
 *
 * It does parse one level of the body, which JiraWebhookResource deliberately does not. Asana
 * batches many events into one delivery, and the processor's model is one delivery, one change;
 * splitting the array here keeps that model intact and keeps per-resource ordering and
 * deduplication working downstream. The parse goes exactly one level deep - the envelope's
 * `events` array - and each element is stored verbatim for the adapter to read later.
 */
@RestResource(urlMapping='/v1/webhook/asana/*')
global with sharing class AsanaWebhookResource {
  private static final String SOURCE_SYSTEM = ExternalSystem.ASANA;
  private static final String SECRET_HEADER = 'X-Hook-Secret';
  private static final String SIGNATURE_HEADER = 'X-Hook-Signature';
  private static final Integer PAYLOAD_MAX = Webhook_Event__c.Raw_Payload__c.getDescribe()
    .getLength();
  private static final Integer EVENT_ERROR_MAX = Webhook_Event__c.Error_Message__c.getDescribe()
    .getLength();
  private static final Integer OFFERED_SIGNATURE_MAX = 24;

  /**
   * Set when something in front of Salesforce has already verified the signature.
   *
   * The seam for the gateway build: terminate the webhook at a gateway, verify there against a
   * secret manager, forward over OAuth JWT. Both paths can then run side by side during cutover.
   * One boolean and one early return, and nothing else is built for it now.
   *
   * A static rather than a custom setting on purpose, and the reason is measured: a site guest
   * cannot read a custom setting at all - `SecurityException: Access to entity denied`, even
   * with the object granted. Flipping this is a deploy, which suits a cutover that happens once.
   */
  @TestVisible
  private static Boolean signatureVerifiedUpstream = false;

  @HttpPost
  global static void receive() {
    RestRequest request = RestContext.request;
    RestResponse response = RestContext.response;
    if (response == null) {
      response = new RestResponse();
      RestContext.response = response;
    }
    response.addHeader('Content-Type', 'application/json');

    Map<String, String> headers = request == null
      ? new Map<String, String>()
      : request.headers;
    String offeredSecret = WebhookSignature.header(headers, SECRET_HEADER);
    String offeredSignature = WebhookSignature.header(
      headers,
      SIGNATURE_HEADER
    );
    String resourceId = resourceIdFrom(request);

    if (String.isNotBlank(offeredSecret)) {
      handshake(response, resourceId, offeredSecret);
      return;
    }
    if (String.isNotBlank(offeredSignature) || signatureVerifiedUpstream) {
      delivery(response, request, resourceId, offeredSignature);
      return;
    }

    // Neither header. Not a handshake, not a delivery, nothing to process.
    record(
      resourceId,
      false,
      null,
      'Rejected: neither ' +
        SECRET_HEADER +
        ' nor ' +
        SIGNATURE_HEADER +
        ' was present, so this is neither a handshake nor a delivery.'
    );
    response.statusCode = 400;
    response.responseBody = json('bad request');
  }

  // ---------- the handshake ----------

  /**
   * Asana's POST /webhooks blocks until this answers, and the only thing it checks is that the
   * X-Hook-Secret header comes back with the same value. Echo it exactly - not re-encoded, not
   * trimmed into a different string - and answer 200.
   *
   * The secret is staged BEFORE the response is built. Apex commits the transaction before the
   * response is sent, so a 200 from here means the row is durable; answering first and writing
   * afterwards would register a webhook whose secret was never recorded, which cannot be
   * repaired without deleting the webhook at the vendor and starting again.
   */
  private static void handshake(
    RestResponse response,
    String resourceId,
    String offeredSecret
  ) {
    if (String.isBlank(resourceId)) {
      record(
        resourceId,
        false,
        null,
        'Rejected handshake: the target URL named no resource gid. Register with ' +
        '<site>/services/apexrest/v1/webhook/asana/<resource_gid>.'
      );
      response.statusCode = 400;
      response.responseBody = json('bad request');
      return;
    }

    if (!WebhookSecretStore.stage(resourceId, SOURCE_SYSTEM, offeredSecret)) {
      // Most often a second registration for a resource that already has one. Refusing is the
      // point: this endpoint is unauthenticated, and letting a caller replace a live secret
      // would let them sign whatever they liked afterwards.
      record(
        resourceId,
        false,
        null,
        'Rejected handshake for resource ' +
          resourceId +
          ': the secret could not be recorded. A secret already staged for this resource is ' +
          'never replaced - delete the existing Webhook_Secret__c row and register again.'
      );
      response.statusCode = 409;
      response.responseBody = json('already registered');
      return;
    }

    record(
      resourceId,
      false,
      null,
      'Handshake accepted for resource ' +
        resourceId +
        '. Secret staged. Deliveries are rejected until it is promoted - run ' +
        'scripts/apex/promote-webhook-secret.apex.'
    );
    // Echoed exactly as received. This is the whole test Asana performs.
    response.addHeader(SECRET_HEADER, offeredSecret);
    response.statusCode = 200;
    response.responseBody = json('handshake accepted');
  }

  // ---------- a delivery ----------

  private static void delivery(
    RestResponse response,
    RestRequest request,
    String resourceId,
    String offeredSignature
  ) {
    Blob rawBody = request == null ? null : request.requestBody;

    // Verified against the raw bytes, before anything reads the body as text. Deserialising
    // and re-serialising changes whitespace and key order, which changes the digest, which
    // fails every signature - so the Blob goes to the verifier untouched.
    Boolean verified = signatureVerifiedUpstream;
    if (!verified) {
      String secret = WebhookSecretStore.activeSecretFor(resourceId);
      verified = WebhookSignature.isValid(rawBody, offeredSignature, secret);
    }

    if (!verified) {
      // One response for every rejection reason. A caller must not be able to tell "wrong
      // signature" from "this resource has no promoted secret" from "no such webhook".
      record(resourceId, false, null, rejectionNote(rawBody, offeredSignature));
      response.statusCode = 401;
      response.responseBody = json('rejected');
      return;
    }

    List<String> events;
    try {
      events = eventsFrom(rawBody);
    } catch (Exception e) {
      record(
        resourceId,
        false,
        null,
        'Rejected: body verified but could not be read as {"events":[...]}. ' +
        Strings.describe(e)
      );
      // The signature proved who sent it, so a body we cannot read is our problem, not theirs.
      // 200 rather than a retry: redelivering the same bytes would fail identically.
      response.statusCode = 200;
      response.responseBody = json('accepted');
      return;
    }

    if (events.isEmpty()) {
      // Asana sends a periodic heartbeat with an empty events array to check the endpoint is
      // still alive. Nothing to stage, and nothing wrong.
      response.statusCode = 200;
      response.responseBody = json('accepted');
      return;
    }

    List<Webhook_Event__c> rows = new List<Webhook_Event__c>();
    for (String event : events) {
      rows.add(
        new Webhook_Event__c(
          Source_System__c = SOURCE_SYSTEM,
          Received_At__c = System.now(),
          Signature_Valid__c = true,
          Processing_Status__c = DeliveryStatus.PENDING,
          // Event_Type__c and External_Id__c stay null. They come out of the payload, and this
          // endpoint reads only the envelope - the adapter fills them in.
          Raw_Payload__c = Strings.truncate(event, PAYLOAD_MAX)
        )
      );
    }

    try {
      insert rows;
    } catch (Exception e) {
      // Nothing was recorded, so claiming success would silently lose the delivery. 500 is the
      // one case where Asana should genuinely try again.
      response.statusCode = 500;
      response.responseBody = json('error');
      return;
    }

    response.statusCode = 200;
    response.responseBody = json('accepted');
  }

  // ---------- reading the envelope ----------

  /**
   * The events array, each element re-serialised on its own.
   *
   * Exactly one level deep. What an event contains is the adapter's business, and this class
   * must not learn it - the element goes to Webhook_Event__c verbatim.
   */
  private static List<String> eventsFrom(Blob rawBody) {
    List<String> events = new List<String>();
    if (rawBody == null) {
      return events;
    }
    Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(
      rawBody.toString()
    );
    Object raw = envelope.get('events');
    if (!(raw instanceof List<Object>)) {
      return events;
    }
    for (Object entry : (List<Object>) raw) {
      events.add(JSON.serialize(entry));
    }
    return events;
  }

  private static String resourceIdFrom(RestRequest request) {
    if (request == null || String.isBlank(request.requestURI)) {
      return null;
    }
    String uri = request.requestURI;
    Integer boundary = uri.lastIndexOf('/');
    if (boundary < 0 || boundary == uri.length() - 1) {
      return null;
    }
    return uri.substring(boundary + 1);
  }

  // ---------- recording ----------

  /**
   * A Webhook_Event__c row that is not a delivery to process: a handshake, or a rejection.
   *
   * Recorded here rather than in Integration_Log__c for the reason JiraWebhookResource gives -
   * this runs as the guest, which has no access to Integration_Log__c and should not gain any.
   * The row is always Failed and always Signature_Valid__c = false, so WebhookEventTrigger never
   * publishes it and nothing downstream ever looks at it.
   */
  private static void record(
    String resourceId,
    Boolean signatureValid,
    String payload,
    String note
  ) {
    try {
      insert new Webhook_Event__c(
        Source_System__c = SOURCE_SYSTEM,
        Received_At__c = System.now(),
        Signature_Valid__c = signatureValid,
        Processing_Status__c = DeliveryStatus.FAILED,
        External_Id__c = resourceId,
        Raw_Payload__c = payload,
        Error_Message__c = Strings.truncate(note, EVENT_ERROR_MAX)
      );
    } catch (Exception e) {
      // Best effort. Failing to record a rejection must not turn into a 500 and an endless
      // retry loop for a request we were never going to accept.
      System.debug(
        LoggingLevel.ERROR,
        'Could not record an Asana webhook outcome: ' + e.getMessage()
      );
    }
  }

  /**
   * What is kept about a request we refused: how big it was, a short digest so repeat attempts
   * are recognisable, and the signature that was offered. Enough to investigate; not enough to
   * be worth sending. The body itself is never stored - anyone who finds this URL can POST to
   * it, and keeping what they send would hand an anonymous caller a large write per request.
   */
  private static String rejectionNote(Blob rawBody, String offered) {
    Integer size = rawBody == null ? 0 : rawBody.size();
    String digest = 'n/a';
    if (rawBody != null) {
      digest = EncodingUtil.convertToHex(
          Crypto.generateDigest('SHA-256', rawBody)
        )
        .substring(0, 16);
    }
    return 'Rejected: signature missing or invalid. Body not stored.' +
      ' bytes=' +
      size +
      ' sha256=' +
      digest +
      ' offered=' +
      (String.isBlank(offered)
        ? '(none)'
        : Strings.truncate(offered, OFFERED_SIGNATURE_MAX));
  }

  private static Blob json(String status) {
    return Blob.valueOf(
      JSON.serialize(new Map<String, Object>{ 'status' => status })
    );
  }
}
