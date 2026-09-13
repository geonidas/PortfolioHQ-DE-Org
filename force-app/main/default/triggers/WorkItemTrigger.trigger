/**
 * Outbound push on a genuine status change.
 *
 * before update stages the record as Pending; after update enqueues the push. Both halves are
 * needed: the adapter skips its callout for anything still marked Synced, so without the staging
 * step a record that had synced once would never sync again - and would report success while
 * doing nothing.
 */
trigger WorkItemTrigger on Work_Item__c(before update, after update) {
    if (Trigger.isBefore) {
        WorkItemTriggerHandler.stageForPush(Trigger.new, Trigger.oldMap);
    } else {
        WorkItemTriggerHandler.pushStatusChanges(Trigger.new, Trigger.oldMap);
    }
}
