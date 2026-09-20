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
  public static void stageForPush(
    List<Work_Item__c> updated,
    Map<Id, Work_Item__c> priorById
  ) {
    if (SyncContext.isOutboundSuppressed()) {
      // Inbound is applying a remote change; the Sync_Status__c it sets is authoritative.
      return;
    }
    for (Work_Item__c item : updated) {
      Work_Item__c prior = priorById == null ? null : priorById.get(item.Id);
      if (!isPushable(item, prior)) {
        continue;
      }
      // Leave it alone if the caller set Sync_Status__c themselves in this same update -
      // an explicit value beats an inferred one.
      if (item.Sync_Status__c == prior.Sync_Status__c) {
        item.Sync_Status__c = SyncStatus.PENDING;
      }
    }
  }

  public static void pushStatusChanges(
    List<Work_Item__c> updated,
    Map<Id, Work_Item__c> priorById
  ) {
    if (SyncContext.isOutboundSuppressed()) {
      return;
    }

    List<Id> toPush = new List<Id>();
    for (Work_Item__c item : updated) {
      Work_Item__c prior = priorById == null ? null : priorById.get(item.Id);
      if (isPushable(item, prior)) {
        toPush.add(item.Id);
      }
    }
    if (!toPush.isEmpty()) {
      WorkItemSyncService.enqueue(toPush);
    }
  }

  /**
   * The one rule both halves share: a genuine Status__c change, to a status that means
   * something, on a record the remote system knows, that is not on public display. Written once
   * so the before and after contexts cannot drift apart - staging a record the after context
   * then declines to push, or the reverse, would each be a silent failure.
   *
   * Vendor-neutral, and deliberately so: the public rule is a property of the work item, not of
   * the system it came from, and a branch on Source_System__c here is exactly what the adapter
   * seam exists to prevent.
   *
   * ---------------------------------------------------------------------------------------
   * Is_Public__c ARRIVED IN BUILD 07 STEP 8 AND CHANGED JIRA'S BEHAVIOUR TOO.
   *
   * Sync is now bidirectional for private items and inbound-only for public ones. A public item
   * is a showcase mirror of something that lives elsewhere: the remote system is its source of
   * truth, and a status typed into Salesforce should not rewrite what the portfolio is showing
   * off. Before this, a status change on ANY record carrying an External_Id__c pushed, public
   * or not - so if a public Jira issue stops responding to a status change made in Salesforce,
   * this is why, and it is intended.
   * ---------------------------------------------------------------------------------------
   */
  private static Boolean isPushable(Work_Item__c item, Work_Item__c prior) {
    return prior != null &&
      prior.Status__c != item.Status__c &&
      item.Status__c != WorkItemStatus.UNSPECIFIED &&
      String.isNotBlank(item.External_Id__c) &&
      item.Is_Public__c != true;
  }
}
