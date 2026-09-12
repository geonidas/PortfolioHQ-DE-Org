/**
 * Decides when a Salesforce-side change should be pushed to the external system.
 *
 * Three guards, and all three are load-bearing:
 *
 * 1. Suppression. Inbound processing sets SyncContext, so applying a webhook cannot bounce back
 *    out. Checked here, synchronously, because the flag does not survive into the async job -
 *    checking it inside the Queueable would be checking an empty context.
 * 2. Status delta. Only an actual Status__c change pushes. This is what really breaks the loop:
 *    an inbound update writing the status it just received produces no delta, and Build 02's
 *    own writeback of Sync_Status__c and Last_Synced__c produces no delta either. Without it,
 *    the timestamp comparison cannot help - every echo really is newer than the last.
 * 3. Unspecified is never pushed. It means "no mapping", so there is nothing to ask Jira for.
 */
public with sharing class WorkItemTriggerHandler {
    public static void pushStatusChanges(List<Work_Item__c> updated, Map<Id, Work_Item__c> priorById) {
        if (SyncContext.isOutboundSuppressed()) {
            return;
        }

        List<Id> toPush = new List<Id>();
        for (Work_Item__c item : updated) {
            Work_Item__c prior = priorById == null ? null : priorById.get(item.Id);
            Boolean statusChanged = prior != null && prior.Status__c != item.Status__c;
            if (statusChanged && item.Status__c != 'Unspecified' && String.isNotBlank(item.External_Id__c)) {
                toPush.add(item.Id);
            }
        }
        if (!toPush.isEmpty()) {
            WorkItemSyncService.enqueue(toPush);
        }
    }
}
