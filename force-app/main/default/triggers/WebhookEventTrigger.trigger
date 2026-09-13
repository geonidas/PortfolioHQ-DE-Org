/**
 * Hands a freshly received delivery to the event bus so processing leaves the guest's context.
 * Publishes nothing for rejected deliveries - an unverified payload is never parsed.
 */
trigger WebhookEventTrigger on Webhook_Event__c(after insert) {
    WebhookEventTriggerHandler.publishReceived(Trigger.new);
}