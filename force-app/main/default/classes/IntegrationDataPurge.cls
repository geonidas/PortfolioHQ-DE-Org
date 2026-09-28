/**
 * Holds Webhook_Event__c and Integration_Log__c to the 50 most recent rows each, nightly.
 *
 * Both tables were flagged as growing unbounded as far back as build 03 and neither ever had a
 * purge. Nothing breaks at this scale - 98 and 59 rows - but "no ceiling" is the property that
 * matters, not the current number, and a demo org that runs for months has no natural end to it.
 *
 * WHY 50, AND WHAT THAT COSTS.
 *
 * Fifty is a debugging window, not an audit trail: enough to see what the last few deliveries did
 * when something looks wrong, and no more. This is a deliberate trade and it is worth naming,
 * because two kinds of row that are genuinely worth keeping go over the edge with everything else:
 *
 *   - Rejected signatures. Webhook_Event__c rows with Signature_Valid__c = false are the only
 *     record that unauthenticated traffic reached a public endpoint, and they cost nothing to
 *     keep because AsanaWebhookResource never stores a rejected body. Under a flat 50-row cap
 *     they age out like anything else.
 *   - Processed deliveries, which are the history of how a work item came to look the way it does.
 *
 * Version 2 archives both to a Big Object before this deletes them. Until then the cap is simply
 * the policy, and the retention question has an honest answer rather than an implied one.
 *
 * WHAT IT WILL NOT DELETE.
 *
 * A Webhook_Event__c still Pending is work in progress, not history, and deleting one would throw
 * away a delivery nobody has applied yet. Pending rows are therefore excluded from BOTH halves of
 * this - the cutoff and the delete - so the cap counts 50 terminal rows and any Pending ones are
 * kept in addition to them rather than instead of them.
 *
 * Excluding it from only the delete is the obvious half-fix and it is wrong. Counting Pending
 * rows towards the cutoff pushes an equal number of terminal rows below it, so five stuck
 * deliveries silently cost five rows of real history. That is backwards in exactly the case that
 * matters: if WorkItemInboundSweeper ever stops, Pending rows pile up, and the purge would then
 * erode the history of what happened just as the outage made it worth reading. Written the wrong
 * way first here, and caught by pendingRowsAreKeptOnTopOfTheCapNotInsteadOfIt.
 *
 * Integration_Log__c has no such state - a log row is terminal when it is written.
 *
 * TIES KEEP MORE, NEVER FEWER. The cutoff is the 50th row's CreatedDate and the delete is a
 * strict `<`, so rows sharing that timestamp all survive. Asana batches deliveries and five
 * landing in the same second is measured, not hypothetical, so this is a real case rather than a
 * theoretical one. A purge that erred the other way would delete a 51st row that is exactly as
 * recent as the 50th it kept.
 *
 * LIMITS.
 *
 *   - Scheduled Apex can do DML but cannot call out. Nothing here calls out.
 *   - The delete query is capped at 10,000 rows, under the 10,000-row DML ceiling, so one run
 *     cannot exceed it however far behind the table has fallen. A larger backlog simply takes
 *     more nights.
 *   - Deleted rows sit in the recycle bin for 15 days and go on consuming storage there, which
 *     would make a nightly purge take a fortnight to show up as anything. They are hard-deleted,
 *     in chunks, and that is irreversible - there is no undelete after this runs.
 *   - One more scheduled job, on top of the sweeper's four. The org allows 100.
 */
public without sharing class IntegrationDataPurge implements Schedulable {
  /** Rows retained per object. A debugging window, not an audit trail - see the header. */
  @TestVisible
  private static final Integer KEEP = 50;

  /** Under the 10,000-row DML ceiling, so one run can never exceed it. */
  private static final Integer DELETE_LIMIT = 10000;

  /** Well under any documented emptyRecycleBin ceiling, and cheap in DML statements. */
  private static final Integer RECYCLE_CHUNK = 200;

  public void execute(SchedulableContext context) {
    purge();
  }

  /**
   * One pass over both objects. Separate from execute so a test - and anonymous Apex - can run a
   * purge without standing up a schedule.
   *
   * @return rows actually removed, by object name. Zero for a table already at or under the cap.
   */
  public static Map<String, Integer> purge() {
    return new Map<String, Integer>{
      'Webhook_Event__c' => purgeWebhookEvents(),
      'Integration_Log__c' => purgeIntegrationLogs()
    };
  }

  private static Integer purgeWebhookEvents() {
    // Pending is excluded from the cutoff as well as from the delete below. Counting it here
    // would let stuck deliveries push real history over the edge one for one.
    Datetime cutoff = cutoffFor(
      [
        SELECT CreatedDate
        FROM Webhook_Event__c
        WHERE Processing_Status__c != :DeliveryStatus.PENDING
        ORDER BY CreatedDate DESC
        LIMIT 1
        OFFSET :OFFSET_TO_CUTOFF
      ]
    );
    if (cutoff == null) {
      return 0;
    }
    return hardDelete(
      [
        SELECT Id
        FROM Webhook_Event__c
        WHERE
          CreatedDate < :cutoff
          AND Processing_Status__c != :DeliveryStatus.PENDING
        LIMIT :DELETE_LIMIT
      ]
    );
  }

  private static Integer purgeIntegrationLogs() {
    Datetime cutoff = cutoffFor(
      [
        SELECT CreatedDate
        FROM Integration_Log__c
        ORDER BY CreatedDate DESC
        LIMIT 1
        OFFSET :OFFSET_TO_CUTOFF
      ]
    );
    if (cutoff == null) {
      return 0;
    }
    return hardDelete(
      [
        SELECT Id
        FROM Integration_Log__c
        WHERE CreatedDate < :cutoff
        LIMIT :DELETE_LIMIT
      ]
    );
  }

  // SOQL OFFSET takes a bind, not an expression, so the arithmetic happens here.
  private static final Integer OFFSET_TO_CUTOFF = KEEP - 1;

  /**
   * The CreatedDate of the KEEPth most recent row, or null when there are fewer than KEEP rows.
   *
   * Null means "nothing to do" rather than "delete everything", which is the safe reading of an
   * empty result and the one a half-populated table depends on.
   */
  private static Datetime cutoffFor(List<SObject> boundary) {
    return boundary.isEmpty()
      ? null
      : (Datetime) boundary[0].get('CreatedDate');
  }

  /**
   * Delete, then empty the recycle bin, and report only what actually went.
   *
   * allOrNone = false because one undeletable row must not take the night's whole purge with it.
   * The recycle bin pass is best effort for the same reason: it is an optimisation on storage,
   * and failing it should not turn a successful purge into an exception at 11pm.
   */
  private static Integer hardDelete(List<SObject> doomed) {
    if (doomed.isEmpty()) {
      return 0;
    }

    List<SObject> deleted = new List<SObject>();
    List<Database.DeleteResult> results = Database.delete(doomed, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        deleted.add(doomed[i]);
      }
    }

    for (Integer i = 0; i < deleted.size(); i += RECYCLE_CHUNK) {
      List<SObject> chunk = new List<SObject>();
      for (
        Integer j = i; j < Math.min(i + RECYCLE_CHUNK, deleted.size()); j++
      ) {
        chunk.add(deleted[j]);
      }
      try {
        Database.emptyRecycleBin(chunk);
      } catch (Exception e) {
        // The rows are deleted either way; they simply linger in the bin for 15 days. Not worth
        // failing the run over, and not worth a log row on an object this class exists to prune.
        System.debug(
          LoggingLevel.WARN,
          'Purge could not empty the recycle bin: ' + e.getMessage()
        );
      }
    }
    return deleted.size();
  }
}
