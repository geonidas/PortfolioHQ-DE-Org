/**
 * The hand-off from the guest's transaction to the processor's.
 *
 * Only a verified, still-pending delivery is worth waking the processor for. The positive case
 * is proven by the processor having run - it alone writes a terminal status - and the negative
 * cases by the row being exactly as it was after the bus has been drained.
 */
@IsTest
private class WebhookEventTriggerHandlerTest {
  private static Webhook_Event__c delivery(
    Boolean signatureValid,
    String status
  ) {
    return new Webhook_Event__c(
      Source_System__c = 'Jira',
      Received_At__c = System.now(),
      Signature_Valid__c = signatureValid,
      Processing_Status__c = status,
      // Deliberately missing its issue object: the processor will fail it, and that failure
      // note is the evidence the processor ran at all.
      Raw_Payload__c = '{"webhookEvent":"jira:issue_updated"}'
    );
  }

  private static Webhook_Event__c reread(Id eventId) {
    return [
      SELECT Processing_Status__c, Error_Message__c
      FROM Webhook_Event__c
      WHERE Id = :eventId
    ];
  }

  @IsTest
  static void aVerifiedPendingDeliveryWakesTheProcessor() {
    Webhook_Event__c event = delivery(true, 'Pending');

    Test.startTest();
    insert event;
    Test.getEventBus().deliver();
    Test.stopTest();

    Webhook_Event__c after = reread(event.Id);
    Assert.areEqual(
      'Failed',
      after.Processing_Status__c,
      'The processor ran and judged the payload - nothing else writes a terminal status.'
    );
    Assert.isTrue(
      after.Error_Message__c.contains('no issue object'),
      'With its own reason: ' + after.Error_Message__c
    );
  }

  @IsTest
  static void aRejectedSignatureIsNeverPublished() {
    // The endpoint writes Failed for these. Pending here isolates the handler's own check on
    // Signature_Valid__c from its check on the status.
    Webhook_Event__c event = delivery(false, 'Pending');

    Test.startTest();
    insert event;
    Test.getEventBus().deliver();
    Test.stopTest();

    Webhook_Event__c after = reread(event.Id);
    Assert.areEqual(
      'Pending',
      after.Processing_Status__c,
      'Nothing consumed it: an unverified payload must never reach the processor.'
    );
    Assert.isNull(after.Error_Message__c, 'And nothing judged it.');
  }

  @IsTest
  static void aDeliveryAlreadyPastPendingIsNotRepublished() {
    Webhook_Event__c event = delivery(true, 'Processed');

    Test.startTest();
    insert event;
    Test.getEventBus().deliver();
    Test.stopTest();

    Webhook_Event__c after = reread(event.Id);
    Assert.areEqual(
      'Processed',
      after.Processing_Status__c,
      'A row that is not Pending is not work.'
    );
    Assert.isNull(after.Error_Message__c);
  }

  @IsTest
  static void onlyTheEligibleRowsInABatchArePublished() {
    List<Webhook_Event__c> events = new List<Webhook_Event__c>{
      delivery(true, 'Pending'),
      delivery(false, 'Pending'),
      delivery(true, 'Ignored')
    };

    Test.startTest();
    insert events;
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(
      'Failed',
      reread(events[0].Id).Processing_Status__c,
      'Eligible: processed.'
    );
    Assert.areEqual(
      'Pending',
      reread(events[1].Id).Processing_Status__c,
      'Unverified: untouched.'
    );
    Assert.areEqual(
      'Ignored',
      reread(events[2].Id).Processing_Status__c,
      'Already terminal: untouched.'
    );
  }
}
