/**
 * Publishes Webhook_Event_Received__e for deliveries worth processing.
 *
 * Runs inside the guest user's transaction, so it stays deliberately thin: no parsing, no reads,
 * no decisions beyond "is this row worth waking the processor for".
 */
public with sharing class WebhookEventTriggerHandler {
    public static void publishReceived(List<Webhook_Event__c> events) {
        List<Webhook_Event_Received__e> toPublish = new List<Webhook_Event_Received__e>();
        for (Webhook_Event__c event : events) {
            // A rejected signature is recorded and then left alone. Nothing downstream should
            // ever deserialise a payload we could not verify.
            if (event.Signature_Valid__c == true && event.Processing_Status__c == 'Pending') {
                toPublish.add(new Webhook_Event_Received__e(Webhook_Event_Id__c = event.Id));
            }
        }
        if (toPublish.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = EventBus.publish(toPublish);
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) {
                for (Database.Error error : result.getErrors()) {
                    System.debug(LoggingLevel.ERROR, 'Could not publish Webhook_Event_Received__e: ' + error.getMessage());
                }
            }
        }
    }
}