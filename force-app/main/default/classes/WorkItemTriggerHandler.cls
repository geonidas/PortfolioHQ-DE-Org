/**
 * Decides when a Salesforce-side change should be pushed to the external system, and refuses a
 * change the source could never hold.
 *
 * Three guards against a push loop, and all three are load-bearing:
 *
 * 1. Suppression. Inbound processing sets SyncContext, so applying a webhook cannot bounce back
 *    out - a title or date that arrives from the source is never sent straight back to it.
 *    Checked here, synchronously, because the flag does not survive into the async job.
 * 2. Field delta. Only an actual change to a pushable field - status, title, start date, due
 *    date - pushes. This is what stops the sync's own write-back (Sync_Status__c,
 *    Last_Synced__c, Pending_Push_Fields__c, Sync_Error__c) from pushing again, and it is why a
 *    delivery that echoes our own push back to us changes nothing. It was Status__c alone until
 *    build 08; SyncFields.changedBetween is now the one definition of "changed".
 * 3. Unspecified is never pushed. It means "no mapping", so there is nothing to ask for.
 *
 * The timestamp comparison in WorkItemInboundProcessor is the fourth mechanism, and handles
 * stale and duplicate deliveries rather than loops.
 *
 * stageForPush is the other half of a push. It records WHICH fields changed in
 * Pending_Push_Fields__c - the adapter must send exactly the fields that changed and nothing
 * else - and marks the record Pending so nothing claims the source agrees before it does.
 * pushChanges hands the job the fields this save changed, so a second save's job does not send
 * the first save's fields again.
 */
public with sharing class WorkItemTriggerHandler {
  /**
   * Refuse a start date on an item whose source cannot hold one.
   *
   * The rule, not a courtesy: the board hides the start date editor for such a source, but the
   * record page, the API and a data load do not, and an unpushable value would sit in Salesforce
   * disagreeing with the source for ever. Checked whether or not outbound is suppressed. Setting
   * one is refused; clearing one never is.
   */
  public static void enforceSourceCapabilities(
    List<Work_Item__c> items,
    Map<Id, Work_Item__c> priorById
  ) {
    for (Work_Item__c item : items) {
      if (item.Start_Date__c == null) {
        continue;
      }
      Work_Item__c prior = priorById == null ? null : priorById.get(item.Id);
      if (prior != null && prior.Start_Date__c == item.Start_Date__c) {
        continue;
      }
      BoardSourceRules.Source source = BoardSourceRules.forSystem(
        item.External_System__c
      );
      if (!source.supportsStartDate) {
        item.Start_Date__c.addError(
          (String.isBlank(source.label)
            ? 'This item\'s source'
            : source.label) +
          ' does not support start dates, so this item cannot have one. Clear the start date.'
        );
      }
    }
  }

  /**
   * Record which pushable fields changed, and mark the record as no longer in agreement with the
   * source. Runs in before update, so it costs no extra DML.
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
      Set<SyncField> changed = SyncFields.changedBetween(item, prior);
      if (changed.isEmpty()) {
        continue;
      }
      // Added to, never replaced: a second edit before the first push lands must not erase the
      // first edit's fields, and a field the source refused stays until a push of it succeeds.
      Set<SyncField> pending = SyncFields.parse(item.Pending_Push_Fields__c);
      pending.addAll(changed);
      item.Pending_Push_Fields__c = SyncFields.serialize(pending);
      // A new attempt is under way, so the last failure's reason no longer describes the record.
      item.Sync_Error__c = null;
      // Leave it alone if the caller set Sync_Status__c themselves in this same update -
      // an explicit value beats an inferred one.
      if (item.Sync_Status__c == prior.Sync_Status__c) {
        item.Sync_Status__c = SyncStatus.PENDING;
      }
    }
  }

  /**
   * Queue one push for every record whose pushable fields changed, owning the fields that
   * changed. Another save's fields belong to that save's job - see WorkItemSyncQueueable.
   *
   * A record that was Failed has no push in flight: the job that was refused has finished, and
   * what it left in Pending_Push_Fields__c belongs to no job. This save's job takes it over, which
   * is what makes "it is sent again with the next change you save" true on the board.
   */
  public static void pushChanges(
    List<Work_Item__c> updated,
    Map<Id, Work_Item__c> priorById
  ) {
    if (SyncContext.isOutboundSuppressed()) {
      return;
    }

    Map<Id, Set<SyncField>> staged = new Map<Id, Set<SyncField>>();
    for (Work_Item__c item : updated) {
      Work_Item__c prior = priorById == null ? null : priorById.get(item.Id);
      Set<SyncField> changed = SyncFields.changedBetween(item, prior);
      if (changed.isEmpty()) {
        continue;
      }
      if (prior != null && prior.Sync_Status__c == SyncStatus.FAILED) {
        changed.addAll(SyncFields.parse(prior.Pending_Push_Fields__c));
      }
      staged.put(item.Id, changed);
    }
    if (!staged.isEmpty()) {
      WorkItemSyncService.enqueueStaged(staged);
    }
  }

  // ---------------------------------------------------------------------------------------
  // Is_Public__c WAS A CONDITION ON PUSHING FOR PART OF BUILD 07 AND IS NOT ONE ANY MORE.
  //
  // Step 8 added `item.Is_Public__c != true`, making sync inbound-only for anything on public
  // display. That was wrong, and it silently changed Jira's behaviour too. Is_Public__c answers
  // "who may READ this record" - it is the guest board's gate, enforced in
  // PublicWorkItemSelector's WHERE clause and in the guest sharing rules. It says nothing about
  // who may WRITE it. Conflating the two made the internal board's edit controls quietly stop
  // working on exactly the records the project exists to show off, and there is no reason a
  // visible item should also be a frozen one.
  //
  // Writability is governed by object and field permissions, not by this flag. Do not put it
  // back - SyncFields.changedBetween is the whole of the rule.
  // ---------------------------------------------------------------------------------------
}
