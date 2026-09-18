/**
 * Inbound webhook endpoint, reachable by the site guest user.
 *
 * Does as little as possible on purpose. Verify the signature over the raw bytes, persist the
 * delivery, answer. No JSON parsing, no business logic, no callouts, no reads of any other
 * object - deserialising unauthenticated input inside the guest transaction is attack surface
 * this endpoint has no reason to carry. Everything downstream happens in another transaction,
 * under another user, off the Webhook_Event__c row.
 *
 * Status codes are chosen for what they make Jira do. A non-2xx is a request to retry, so it is
 * reserved for failures where retrying would actually help: we return 500 only when the delivery
 * could not be recorded. A payload that will later be ignored still gets a 200, because there is
 * nothing to retry. An invalid signature gets a 401 and is never retried into acceptance.
 *
 * Unverified bodies are never stored. Anyone who finds this URL can POST to it, and storing what
 * they send would hand an anonymous caller a 128 KB write per request. A rejected attempt is
 * still recorded - the row, the size, and a digest prefix are enough to recognise a flood or
 * correlate repeats - but the content itself is dropped, which is roughly a 600-fold reduction
 * in what an unauthenticated caller can cost.
 */
@RestResource(urlMapping='/v1/webhook/jira')
global with sharing class JiraWebhookResource {
  private static final String SOURCE_SYSTEM = ExternalSystem.JIRA;
  private static final String SIGNATURE_HEADER = 'X-Hub-Signature';
  private static final Integer PAYLOAD_MAX = Webhook_Event__c.Raw_Payload__c.getDescribe()
    .getLength();
  private static final Integer OFFERED_SIGNATURE_MAX = 24;

  @HttpPost
  global static void receive() {
    RestRequest request = RestContext.request;
    RestResponse response = RestContext.response;
    if (response == null) {
      response = new RestResponse();
      RestContext.response = response;
    }
    response.addHeader('Content-Type', 'application/json');

    Blob rawBody = request == null ? null : request.requestBody;

    // Verified against the raw bytes, before anything touches the body as text.
    String secret = IntegrationSecretService.activeSecret(
      IntegrationSecretService.JIRA_WEBHOOK
    );
    String offered = WebhookSignature.header(
      request == null ? null : request.headers,
      SIGNATURE_HEADER
    );
    Boolean signatureValid = WebhookSignature.isValid(rawBody, offered, secret);

    Webhook_Event__c event = new Webhook_Event__c(
      Source_System__c = SOURCE_SYSTEM,
      Received_At__c = System.now(),
      Signature_Valid__c = signatureValid,
      // Event_Type__c and External_Id__c stay null here. They come out of the payload, and
      // the payload is not parsed in this context - the processor fills them in.
      Processing_Status__c = signatureValid
        ? DeliveryStatus.PENDING
        : DeliveryStatus.FAILED,
      // Bodies are stored only once they are proven to come from Jira. A rejected request
      // leaves a fingerprint instead - see rejectionNote.
      Raw_Payload__c = signatureValid ? asText(rawBody) : null,
      Error_Message__c = signatureValid ? null : rejectionNote(rawBody, offered)
    );

    try {
      insert event;
    } catch (Exception e) {
      // Nothing was recorded, so claiming success would silently lose the delivery. 500 is
      // the one case where we genuinely want Jira to try again.
      response.statusCode = 500;
      response.responseBody = json('error');
      return;
    }

    if (!signatureValid) {
      // One response for every rejection reason. A caller must not be able to distinguish
      // "wrong signature" from "this org has no secret configured".
      response.statusCode = 401;
      response.responseBody = json('rejected');
      return;
    }

    response.statusCode = 200;
    response.responseBody = json('accepted');
  }

  /**
   * What we keep about a request we refused: how big it was, a short digest so repeat attempts
   * are recognisable, and the signature that was offered. Enough to investigate; not enough to
   * be worth sending.
   *
   * Deliberately no rate limit on top of this. Capping rows would mean counting existing ones,
   * and this class runs `with sharing` as the guest user, who cannot read the rows it creates -
   * so the count would silently return zero and the cap would never fire. Making it work would
   * need a `without sharing` class reachable from an unauthenticated endpoint, which is the one
   * thing this design refuses.
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

  /**
   * Body as text for storage only - the signature was already checked against the bytes.
   * Non-UTF-8 input is stored as a marker rather than being allowed to throw, so a hostile
   * payload cannot turn into a 500 and an endless Jira retry loop.
   */
  private static String asText(Blob rawBody) {
    if (rawBody == null) {
      return null;
    }
    String text;
    try {
      text = rawBody.toString();
    } catch (Exception e) {
      return '[unreadable body: ' + rawBody.size() + ' bytes]';
    }
    return Strings.truncate(text, PAYLOAD_MAX);
  }

  private static Blob json(String status) {
    return Blob.valueOf(
      JSON.serialize(new Map<String, Object>{ 'status' => status })
    );
  }
}
