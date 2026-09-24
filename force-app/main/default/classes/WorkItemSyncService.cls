/**
 * Orchestrates outbound sync: push each item's pending fields, buffer the logs, write back what
 * the source confirmed.
 *
 * The ordering here is not stylistic. Apex refuses a callout once the transaction has pending
 * DML, so every callout in a chunk happens first and all DML happens at the end - work items
 * before logs, so that a logging failure can never take the sync down with it.
 *
 * One transaction's worth only. Chunking and chaining are WorkItemSyncQueueable's job.
 */
public with sharing class WorkItemSyncService {
  /**
   * Items per transaction. Up to three callouts each against a limit of 100 - a Jira field edit
   * plus a two-step transition - so 33 is the count ceiling. Two until build 08, when title and
   * date edits became pushable. The tighter real constraint may be the platform's 120 seconds of
   * cumulative callout time, which is why calloutTimeBudgetMs exists rather than trusting this
   * number alone.
   */
  public static final Integer DEFAULT_CHUNK_SIZE = 33;

  private static final Integer CALLOUTS_PER_ITEM = 3;

  private static final Integer SYNC_ERROR_MAX = Work_Item__c.Sync_Error__c.getDescribe()
    .getLength();

  // Stop well inside the platform's 120s ceiling: being killed mid-chunk loses the log buffer.
  @TestVisible
  private static Integer calloutTimeBudgetMs = 90000;

  private static final Integer LOG_ERROR_MAX = Integration_Log__c.Error_Message__c.getDescribe()
    .getLength();

  /**
   * Fields the push needs: which fields are waiting, and the current value of each one that can
   * be pushed.
   */
  public static final String ITEM_FIELDS =
    'Id, External_Id__c, External_System__c, Status__c, Sync_Status__c, Last_Synced__c, ' +
    'Title__c, Start_Date__c, Due_Date__c, Pending_Push_Fields__c';

  /**
   * Push each item's pending fields to its external system, with their current values.
   *
   * @param items work items queried with ITEM_FIELDS, at most DEFAULT_CHUNK_SIZE of them
   * @return      one result per item actually attempted; short of the input when the callout
   *              budget ran out, which tells the caller what still needs doing
   */
  public static List<SyncResult> pushPending(List<Work_Item__c> items) {
    List<SyncResult> results = new List<SyncResult>();
    if (items == null || items.isEmpty()) {
      return results;
    }

    Map<String, IWorkItemAdapter> adapters = new Map<String, IWorkItemAdapter>();
    List<Integration_Log__c> logs = new List<Integration_Log__c>();
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
          Strings.describe(e),
          null
        );
        rejected.workItemId = item.Id;
        rejected.externalId = item.External_Id__c;
        results.add(rejected);
        logs.add(outcomeLog(item, rejected));
        continue;
      }

      Set<SyncField> pending = SyncFields.parse(item.Pending_Push_Fields__c);
      if (pending.isEmpty()) {
        // An earlier job already pushed it. Nothing is sent, and nothing is written back -
        // writing Synced here could overwrite a Failed that job recorded.
        SyncResult idle = SyncResult.nothingToPush();
        idle.workItemId = item.Id;
        idle.externalId = item.External_Id__c;
        results.add(idle);
        continue;
      }

      Long startedAt = System.currentTimeMillis();
      SyncResult result;
      try {
        result = adapter.push(item, pending);
      } catch (Exception e) {
        // The adapter contracts not to throw for business outcomes, so anything here is
        // genuinely unexpected. Swallow it per item so one bad record cannot strand the
        // other 49 and their buffered logs.
        result = SyncResult.failure(
          SyncResult.Outcome.CALLOUT_FAILED,
          Strings.describe(e),
          0
        );
        result.workItemId = item.Id;
        result.externalId = item.External_Id__c;
      }
      calloutMsUsed += System.currentTimeMillis() - startedAt;

      logs.addAll(adapter.drainLogs());
      if (!result.isSuccess()) {
        logs.add(outcomeLog(item, result));
      }
      results.add(result);
    }

    // Callouts are finished. DML from here down.
    logs.addAll(commitItems(writeBack(results)));
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
    Boolean callsLeft =
      (Limits.getLimitCallouts() - Limits.getCallouts()) >= CALLOUTS_PER_ITEM;
    return callsLeft && calloutMsUsed < calloutTimeBudgetMs;
  }

  private static IWorkItemAdapter adapterFor(
    Work_Item__c item,
    Map<String, IWorkItemAdapter> cache
  ) {
    String key = ExternalIdUtil.namespaceOf(item.External_Id__c);
    if (!cache.containsKey(key)) {
      cache.put(key, WorkItemAdapterFactory.forSystem(key));
    }
    return cache.get(key);
  }

  /**
   * The sync fields each result earns, computed against the row as it is NOW.
   *
   * Re-read under a lock, after the callouts, because the user may have edited the record while
   * its push was in flight. That edit added to Pending_Push_Fields__c and queued a job of its
   * own; subtracting only what this push confirmed from what is stored now keeps it, where
   * writing back the set this job started with would erase it - and the queued job would then
   * find nothing to push and the record would read Synced with the edit never sent. FOR UPDATE
   * makes an edit arriving during this write wait for it rather than race it.
   *
   *   every field confirmed, nothing else waiting  Synced, Last_Synced__c, Sync_Error__c cleared
   *   confirmed, but a newer edit is waiting       stays Pending - its own job is queued
   *   refused or broken                            Failed, with the reason in Sync_Error__c; what
   *                                                the source refused stays pending
   *
   * Last_Synced__c moves only on success, so it keeps meaning "the last time Salesforce and the
   * remote system actually agreed" rather than "the last time we tried". Synced is illegal beside
   * an Unspecified status (Sync_Status_Requires_Known_Status), so such a record stays Pending -
   * which is also what inbound sync calls it.
   */
  private static List<Work_Item__c> writeBack(List<SyncResult> results) {
    Map<Id, SyncResult> byId = new Map<Id, SyncResult>();
    for (SyncResult result : results) {
      if (
        result.workItemId != null &&
        result.outcome != SyncResult.Outcome.NOTHING_TO_PUSH
      ) {
        byId.put(result.workItemId, result);
      }
    }
    List<Work_Item__c> updates = new List<Work_Item__c>();
    if (byId.isEmpty()) {
      return updates;
    }
    Set<Id> ids = byId.keySet();
    for (Work_Item__c current : [
      SELECT Id, Status__c, Pending_Push_Fields__c
      FROM Work_Item__c
      WHERE Id IN :ids
      FOR UPDATE
    ]) {
      SyncResult result = byId.get(current.Id);
      Set<SyncField> remaining = SyncFields.parse(
        current.Pending_Push_Fields__c
      );
      remaining.removeAll(result.confirmedFields);

      Work_Item__c updatedItem = new Work_Item__c(
        Id = current.Id,
        Pending_Push_Fields__c = SyncFields.serialize(remaining)
      );
      if (!result.isSuccess()) {
        updatedItem.Sync_Status__c = SyncStatus.FAILED;
        updatedItem.Sync_Error__c = Strings.truncate(
          result.message,
          SYNC_ERROR_MAX
        );
      } else if (
        remaining.isEmpty() && current.Status__c != WorkItemStatus.UNSPECIFIED
      ) {
        updatedItem.Sync_Status__c = SyncStatus.SYNCED;
        updatedItem.Last_Synced__c = System.now();
        updatedItem.Sync_Error__c = null;
      } else {
        updatedItem.Sync_Status__c = SyncStatus.PENDING;
        updatedItem.Sync_Error__c = null;
      }
      updates.add(updatedItem);
    }
    return updates;
  }

  /**
   * A log row for an outcome that no callout produced - a rejected request, or a transition the
   * workflow does not allow. These carry no HTTP_Method__c or Endpoint__c, which is what tells
   * them apart from callout rows.
   */
  private static Integration_Log__c outcomeLog(
    Work_Item__c item,
    SyncResult result
  ) {
    return new Integration_Log__c(
      Direction__c = LogDirection.OUTBOUND,
      Status_Code__c = result.statusCode == null ? 0 : result.statusCode,
      Error_Message__c = Strings.truncate(
        result.outcome.name() + ': ' + result.message,
        LOG_ERROR_MAX
      ),
      Work_Item__c = item.Id,
      Is_Success__c = false
    );
  }

  /**
   * @return log rows describing any rows that failed to update, so a partial failure is visible
   */
  private static List<Integration_Log__c> commitItems(
    List<Work_Item__c> updates
  ) {
    List<Integration_Log__c> failures = new List<Integration_Log__c>();
    if (updates.isEmpty()) {
      return failures;
    }
    // None of these fields is pushable, so the trigger would find nothing to push anyway.
    // Suppressing makes that certain rather than a consequence of another class's rule.
    SyncContext.suppressOutbound();
    List<Database.SaveResult> saveResults;
    try {
      saveResults = Database.update(updates, false);
    } finally {
      SyncContext.resumeOutbound();
    }
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
          Direction__c = LogDirection.OUTBOUND,
          Status_Code__c = 0,
          Error_Message__c = Strings.truncate(
            'Could not write sync fields. ' + String.join(messages, ' | '),
            LOG_ERROR_MAX
          ),
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
      System.debug(
        LoggingLevel.ERROR,
        'Integration_Log__c insert failed, continuing: ' + Strings.describe(e)
      );
    }
  }
}
