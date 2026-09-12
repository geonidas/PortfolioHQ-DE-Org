/**
 * Async driver for outbound sync. Callouts cannot run from a trigger, and one transaction cannot
 * hold more than 100 of them, so work is taken a chunk at a time and the remainder is chained
 * into a fresh transaction with fresh limits.
 *
 * The job carries the whole outstanding list rather than a pre-cut slice. If a chunk stops early
 * because the callout time budget ran out, whatever it did not reach is simply still in the list
 * for the next link in the chain.
 */
public class WorkItemSyncQueueable implements Queueable, Database.AllowsCallouts {
    private final List<Id> pending;

    public WorkItemSyncQueueable(List<Id> workItemIds) {
        this.pending = workItemIds == null ? new List<Id>() : new List<Id>(workItemIds);
    }

    public void execute(QueueableContext context) {
        if (pending.isEmpty()) {
            return;
        }

        List<Id> slice = new List<Id>();
        Integer take = Math.min(WorkItemSyncService.DEFAULT_CHUNK_SIZE, pending.size());
        for (Integer i = 0; i < take; i++) {
            slice.add(pending[i]);
        }

        List<Work_Item__c> items = Database.query(
            'SELECT ' + WorkItemSyncService.ITEM_FIELDS + ' FROM Work_Item__c WHERE Id IN :slice'
        );

        List<SyncResult> results = WorkItemSyncService.syncStatuses(items);

        Set<Id> attempted = new Set<Id>();
        for (SyncResult result : results) {
            if (result.workItemId != null) {
                attempted.add(result.workItemId);
            }
        }

        // Ids in the slice that came back from the query but were not reached - the budget ran
        // out - go round again. Ids that the query did not return at all are dropped: the record
        // was deleted, and carrying it forever would spin the chain.
        Set<Id> found = new Map<Id, Work_Item__c>(items).keySet();
        Set<Id> sliced = new Set<Id>(slice);
        List<Id> leftover = new List<Id>();
        for (Id workItemId : pending) {
            Boolean inThisSlice = sliced.contains(workItemId);
            if (!inThisSlice || (found.contains(workItemId) && !attempted.contains(workItemId))) {
                leftover.add(workItemId);
            }
        }

        if (leftover.isEmpty()) {
            return;
        }
        // No forward progress means chaining again would loop for ever.
        if (leftover.size() >= pending.size()) {
            System.debug(
                LoggingLevel.ERROR,
                'WorkItemSyncQueueable made no progress on ' + pending.size() + ' work items; stopping the chain.'
            );
            return;
        }
        // Queueables cannot chain in a test context; the assertions cover chunking directly.
        if (!Test.isRunningTest()) {
            System.enqueueJob(new WorkItemSyncQueueable(leftover));
        }
    }
}