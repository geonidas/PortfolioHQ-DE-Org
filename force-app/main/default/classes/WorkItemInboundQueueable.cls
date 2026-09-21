/**
 * Applies staged inbound deliveries, in a context where an adapter is allowed to call out.
 *
 * This class exists because of one platform rule: Apex refuses a callout made from a TRIGGER, and
 * the inbound path's entry point is a trigger - the subscriber on Webhook_Event_Received__e.
 * Jira never noticed, because its payloads are fat and JiraAdapter calls out for nothing. Asana's
 * payloads name a gid and an action and nothing else, so AsanaAdapter must fetch the task, and the
 * very first live delivery came back
 *
 *   System.CalloutException: Callout from triggers are currently not supported.
 *
 * with the delivery left staged and no work item created. No test caught it: every test calls
 * WorkItemInboundProcessor.process directly, so nothing ever ran the adapter as the thing that
 * actually runs it. See WorkItemInboundQueueableTest for the test that does.
 *
 * The shape is the one the outbound path has used since build 02. WorkItemTriggerHandler does not
 * call out either; it enqueues WorkItemSyncQueueable and lets that do the work. Inbound now
 * mirrors it, which means there is one answer to "where do callouts happen" on both paths.
 *
 * Every system goes through here, not just the ones that call out. Routing Asana async and Jira
 * inline would mean this class knowing which adapters hydrate - exactly the vendor knowledge the
 * adapter seam exists to keep out of shared code. Jira deliveries simply gain the latency of a
 * queued job, which is nothing next to the webhook round trip that preceded them.
 */
public without sharing class WorkItemInboundQueueable implements Queueable, Database.AllowsCallouts {
  private final List<Id> eventIds;

  public WorkItemInboundQueueable(Set<Id> eventIds) {
    this.eventIds = eventIds == null ? new List<Id>() : new List<Id>(eventIds);
  }

  public void execute(QueueableContext context) {
    if (eventIds.isEmpty()) {
      return;
    }
    // Re-read rather than carrying the rows across. A delivery already retired by another run -
    // superseded, or processed on a retry - must not be applied twice, and the WHERE clause is
    // what guarantees that whatever happened between the publish and this job running.
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
          Id IN :eventIds
          AND Processing_Status__c = :DeliveryStatus.PENDING
          AND Signature_Valid__c = TRUE
      ]
    );
  }
}
