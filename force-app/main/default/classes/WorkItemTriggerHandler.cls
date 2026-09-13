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
 *
 * stageForPush is the other half. JiraAdapter declines to call out for a record still marked
 * Synced, on the reasoning that Salesforce already believes the remote agrees. That belief is
 * stale the instant someone edits Status__c here, so a status change has to reset it - otherwise
 * the record syncs exactly once and every later change is silently skipped while still being
 * stamped Synced.
 */
public with sharing class WorkItemTriggerHandler {
    /**
     * Mark a locally changed record as no longer in agreement with the remote system, so the
     * adapter does not skip the push. Runs in before update, so it costs no extra DML.
     */
    public static void stageForPush(List<Work_Item__c> updated, Map<Id, Work_Item__c> priorById) {
        if (SyncContext.isOutboundSuppressed()) {
            // Inbound is applying a remote change; the Sync_Status__c it sets is authoritative.
            return;
        }
        for (Work_Item__c item : updated) {
            Work_Item__c prior = priorById == null ? null : priorById.get(item.Id);
            if (prior == null || prior.Status__c == item.Status__c) {
                continue;
            }
            if (item.Status__c == 'Unspecified' || String.isBlank(item.External_Id__c)) {
                continue;
            }
            // Leave it alone if the caller set Sync_Status__c themselves in this same update -
            // an explicit value beats an inferred one.
            if (item.Sync_Status__c == prior.Sync_Status__c) {
                item.Sync_Status__c = 'Pending';
            }
        }
    }

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