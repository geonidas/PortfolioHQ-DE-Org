/**
 * Outbound push on a genuine status change. After update only: an insert has nothing to push to
 * yet, and Build 02's sync writes back Sync_Status__c and Last_Synced__c on every run, which
 * must not read as a reason to sync again.
 */
trigger WorkItemTrigger on Work_Item__c(after update) {
    WorkItemTriggerHandler.pushStatusChanges(Trigger.new, Trigger.oldMap);
}