/**
 * Async driver for outbound sync. Callouts cannot run from a trigger, and one transaction cannot
 * hold more than 100 of them, so work is taken a chunk at a time and the remainder is chained
 * into a fresh transaction with fresh limits.
 *
 * The job carries the whole outstanding list rather than a pre-cut slice. If a chunk stops early
 * because the callout time budget ran out, whatever it did not reach is simply still in the list
 * for the next link in the chain.
 *
 * A job queued by a save owns the fields that save staged, and sends only those while another
 * push is queued or running - so two saves seconds apart push each field once, not the first
 * save's fields twice. With no other push in flight nothing else can be holding a field, so the
 * job sends everything still pending: a field whose own job died after calling out, or before
 * writing back, goes with the next push rather than waiting for ever.
 *
 * `without sharing` states what an unqualified Queueable already did: this is a system process
 * finishing a push that a trigger already committed to. Sharing was checked when the user made
 * the change; the job's only reads are the ids it was handed, and its only writes are the sync
 * fields on those same records. Enforcing sharing here would let a record the enqueuing user
 * has since lost sight of go silently unsynced.
 */
public without sharing class WorkItemSyncQueueable implements Queueable, Database.AllowsCallouts {
  private final List<Id> pending;
  // Per item, the fields the save that queued this job staged. Null for a job that owns no
  // particular fields and sends whatever is pending.
  private final Map<Id, Set<SyncField>> staged;

  /** Tests set this to stand in for the AsyncApexJob count; null asks the org. */
  @TestVisible
  private static Boolean assumeOtherPushesInFlight;

  public WorkItemSyncQueueable(List<Id> workItemIds) {
    this.pending = workItemIds == null
      ? new List<Id>()
      : new List<Id>(workItemIds);
    this.staged = null;
  }

  public WorkItemSyncQueueable(Map<Id, Set<SyncField>> stagedFields) {
    this.staged = stagedFields == null
      ? new Map<Id, Set<SyncField>>()
      : stagedFields;
    this.pending = new List<Id>(this.staged.keySet());
  }

  public void execute(QueueableContext context) {
    if (pending.isEmpty()) {
      return;
    }

    List<Id> slice = new List<Id>();
    Integer take = Math.min(
      WorkItemSyncService.DEFAULT_CHUNK_SIZE,
      pending.size()
    );
    for (Integer i = 0; i < take; i++) {
      slice.add(pending[i]);
    }

    List<Work_Item__c> items = Database.query(
      'SELECT ' +
        WorkItemSyncService.ITEM_FIELDS +
        ' FROM Work_Item__c WHERE Id IN :slice'
    );

    // Only while another push could be holding a field does this one keep to its own.
    Map<Id, Set<SyncField>> owned;
    if (staged != null && otherPushesInFlight(context)) {
      owned = new Map<Id, Set<SyncField>>();
      for (Id workItemId : slice) {
        owned.put(workItemId, staged.get(workItemId));
      }
    }
    List<SyncResult> results = WorkItemSyncService.pushPending(items, owned);

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
      if (
        !inThisSlice ||
        (found.contains(workItemId) && !attempted.contains(workItemId))
      ) {
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
        'WorkItemSyncQueueable made no progress on ' +
          pending.size() +
          ' work items; stopping the chain.'
      );
      return;
    }
    // Queueables cannot chain in a test context; the assertions cover chunking directly.
    if (!Test.isRunningTest()) {
      System.enqueueJob(continuation(leftover));
    }
  }

  /** The rest of the chain, owning what this job owned for the items it did not reach. */
  private WorkItemSyncQueueable continuation(List<Id> leftover) {
    if (staged == null) {
      return new WorkItemSyncQueueable(leftover);
    }
    Map<Id, Set<SyncField>> rest = new Map<Id, Set<SyncField>>();
    for (Id workItemId : leftover) {
      rest.put(workItemId, staged.get(workItemId));
    }
    return new WorkItemSyncQueueable(rest);
  }

  /**
   * Whether any other push job is queued or running. One query, and coarse on purpose: it does
   * not ask which items the others carry, only whether a field could be held elsewhere. In an org
   * this size the answer is usually no, and the job then sends everything pending.
   */
  private static Boolean otherPushesInFlight(QueueableContext context) {
    if (assumeOtherPushesInFlight != null) {
      return assumeOtherPushesInFlight;
    }
    Id self = context == null ? null : context.getJobId();
    return [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE
          ApexClass.Name = 'WorkItemSyncQueueable'
          AND Status IN ('Queued', 'Preparing', 'Processing', 'Holding')
          AND Id != :self
      ] > 0;
  }
}
