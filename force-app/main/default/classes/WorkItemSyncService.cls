/**
 * Orchestrates outbound status sync: call the adapter, buffer the logs, write the sync fields.
 *
 * The ordering here is not stylistic. Apex refuses a callout once the transaction has pending
 * DML, so every callout in a chunk happens first and all DML happens at the end - work items
 * before logs, so that a logging failure can never take the sync down with it.
 *
 * One transaction's worth only. Chunking and chaining are WorkItemSyncQueueable's job.
 */
public with sharing class WorkItemSyncService {
    /**
     * Items per transaction. Two callouts each against a limit of 100, so 50 is the count ceiling.
     * The tighter real constraint is the platform's 120 seconds of cumulative callout time, which
     * is why CALLOUT_TIME_BUDGET_MS exists rather than trusting this number alone.
     */
    public static final Integer DEFAULT_CHUNK_SIZE = 50;

    private static final Integer CALLOUTS_PER_ITEM = 2;

    // Stop well inside the platform's 120s ceiling: being killed mid-chunk loses the log buffer.
    @TestVisible
    private static Integer calloutTimeBudgetMs = 90000;

    /**
     * Fields the sync needs. Status__c is both the value pushed and, with Sync_Status__c, the
     * basis for skipping an item we already believe is in the right remote state.
     */
    public static final String ITEM_FIELDS = 'Id, External_Id__c, External_System__c, Status__c, Sync_Status__c, Last_Synced__c';

    /**
     * Push each item's current Status__c to its external system.
     *
     * @param items work items to sync, at most DEFAULT_CHUNK_SIZE of them
     * @return      one result per item actually attempted; short of the input when the callout
     *              budget ran out, which tells the caller what still needs doing
     */
    public static List<SyncResult> syncStatuses(List<Work_Item__c> items) {
        List<SyncResult> results = new List<SyncResult>();
        if (items == null || items.isEmpty()) {
            return results;
        }

        Map<String, IWorkItemAdapter> adapters = new Map<String, IWorkItemAdapter>();
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        List<Work_Item__c> updates = new List<Work_Item__c>();
        Long calloutMsUsed = 0;

        for (Work_Item__c item : items) {
            if (!hasBudget(calloutMsUsed)) {
                break; // leave the rest unattempted rather than get killed mid-chunk
            }

            IWorkItemAdapter adapter;
            try {
                adapter = adapterFor(item, adapters);
            } catch (Exception e) {
                SyncResult rejected = SyncResult.failure(
                    SyncResult.Outcome.BAD_REQUEST,
                    describe(e),
                    null
                );
                rejected.workItemId = item.Id;
                rejected.externalId = item.External_Id__c;
                results.add(rejected);
                logs.add(outcomeLog(item, rejected));
                updates.add(withSyncFields(item, rejected));
                continue;
            }

            Long startedAt = System.currentTimeMillis();
            SyncResult result;
            try {
                result = adapter.updateStatus(item, item.Status__c);
            } catch (Exception e) {
                // The adapter contracts not to throw for business outcomes, so anything here is
                // genuinely unexpected. Swallow it per item so one bad record cannot strand the
                // other 49 and their buffered logs.
                result = SyncResult.failure(SyncResult.Outcome.CALLOUT_FAILED, describe(e), 0);
                result.workItemId = item.Id;
                result.externalId = item.External_Id__c;
            }
            calloutMsUsed += System.currentTimeMillis() - startedAt;

            logs.addAll(adapter.drainLogs());
            if (!result.isSuccess()) {
                logs.add(outcomeLog(item, result));
            }
            results.add(result);
            updates.add(withSyncFields(item, result));
        }

        // Callouts are finished. DML from here down.
        logs.addAll(commitItems(updates));
        commitLogs(logs);
        return results;
    }

    /**
     * Queue the whole set for async processing, chunked and chained.
     *
     * @return the job id of the first chunk, null if there was nothing to do
     */
    public static Id enqueue(List<Id> workItemIds) {
        if (workItemIds == null || workItemIds.isEmpty()) {
            return null;
        }
        return System.enqueueJob(new WorkItemSyncQueueable(workItemIds));
    }

    // ---------- internals ----------

    private static Boolean hasBudget(Long calloutMsUsed) {
        Boolean callsLeft = (Limits.getLimitCallouts() - Limits.getCallouts()) >= CALLOUTS_PER_ITEM;
        return callsLeft && calloutMsUsed < calloutTimeBudgetMs;
    }

    private static IWorkItemAdapter adapterFor(Work_Item__c item, Map<String, IWorkItemAdapter> cache) {
        String key = ExternalIdUtil.namespaceOf(item.External_Id__c);
        if (!cache.containsKey(key)) {
            cache.put(key, WorkItemAdapterFactory.forSystem(key));
        }
        return cache.get(key);
    }

    /**
     * Last_Synced__c moves only on success, so it keeps meaning "the last time Salesforce and the
     * remote system actually agreed" rather than "the last time we tried".
     */
    private static Work_Item__c withSyncFields(Work_Item__c item, SyncResult result) {
        Work_Item__c updatedItem = new Work_Item__c(Id = item.Id);
        if (result.isSuccess()) {
            updatedItem.Sync_Status__c = 'Synced';
            updatedItem.Last_Synced__c = System.now();
        } else {
            updatedItem.Sync_Status__c = 'Failed';
        }
        return updatedItem;
    }

    /**
     * A log row for an outcome that no callout produced - a rejected request, or a transition the
     * workflow does not allow. These carry no HTTP_Method__c or Endpoint__c, which is what tells
     * them apart from callout rows.
     */
    private static Integration_Log__c outcomeLog(Work_Item__c item, SyncResult result) {
        return new Integration_Log__c(
            Direction__c = 'Outbound',
            Status_Code__c = result.statusCode == null ? 0 : result.statusCode,
            Error_Message__c = truncate(result.outcome.name() + ': ' + result.message, 32768),
            Work_Item__c = item.Id,
            Is_Success__c = false
        );
    }

    /**
     * @return log rows describing any rows that failed to update, so a partial failure is visible
     */
    private static List<Integration_Log__c> commitItems(List<Work_Item__c> updates) {
        List<Integration_Log__c> failures = new List<Integration_Log__c>();
        if (updates.isEmpty()) {
            return failures;
        }
        List<Database.SaveResult> saveResults = Database.update(updates, false);
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (saveResults[i].isSuccess()) {
                continue;
            }
            List<String> messages = new List<String>();
            for (Database.Error error : saveResults[i].getErrors()) {
                messages.add(error.getStatusCode() + ': ' + error.getMessage());
            }
            failures.add(
                new Integration_Log__c(
                    Direction__c = 'Outbound',
                    Status_Code__c = 0,
                    Error_Message__c = truncate('Could not write sync fields. ' + String.join(messages, ' | '), 32768),
                    Work_Item__c = updates[i].Id,
                    Is_Success__c = false
                )
            );
        }
        return failures;
    }

    /**
     * Best effort by contract: logging is observability, and losing it must never fail a sync
     * that already succeeded remotely.
     */
    private static void commitLogs(List<Integration_Log__c> logs) {
        if (logs.isEmpty()) {
            return;
        }
        try {
            Database.insert(logs, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Integration_Log__c insert failed, continuing: ' + describe(e));
        }
    }

    private static String describe(Exception e) {
        return e.getTypeName() + ': ' + e.getMessage();
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength - 3) + '...';
    }
}