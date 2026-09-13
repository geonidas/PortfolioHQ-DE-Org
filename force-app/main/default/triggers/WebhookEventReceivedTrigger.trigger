/**
 * Subscriber. Runs as the Automated Process user, which is the point of routing through an event.
 */
trigger WebhookEventReceivedTrigger on Webhook_Event_Received__e(after insert) {
    JiraWebhookProcessor.handle(Trigger.new);
}