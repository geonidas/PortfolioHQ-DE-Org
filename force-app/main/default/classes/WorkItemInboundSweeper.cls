/**
 * Picks up staged deliveries the fast path did not finish, and retires the ones that never will.
 *
 * WHY THIS EXISTS AT ALL.
 *
 * WorkItemInboundProcessor has always said, of a delivery the adapter returned nothing for:
 * "The row is left exactly as it was found, still Pending, for the next run to pick up." There
 * was no next run. Nothing in the org swept Pending rows, so that sentence described an
 * intention rather than a mechanism, and two different things silently accumulated behind it:
 *
 *   - Deliveries about a resource the adapter has nothing to say about. Asana emits a `story`
 *     event for every comment, section change and assignment, and AsanaAdapter returns null for
 *     any resource_type that is not `task`. Those rows were never going to become work items,
 *     and they sat Pending for ever. Thirty of them had collected by the time this was written.
 *   - Deliveries that genuinely deserved another attempt, such as an adapter that ran out of
 *     callouts partway through a batch. Indistinguishable from the first kind, and equally
 *     stranded.
 *
 * This class drains both: it retries a row a bounded number of times and then retires it. The
 * second half matters more than the first. A sweeper with no ceiling re-reads the permanently
 * stuck rows on every run for ever, and the query it runs grows without limit until it hits the
 * 50,000-row governor and the sweeper itself starts failing - which would replace a tidy leak
 * with a broken safety net.
 *
 * WHY IT ENQUEUES INSTEAD OF DOING THE WORK.
 *
 * Scheduled Apex cannot make callouts. Not a policy choice - a callout attempted from a
 * Schedulable's execute fails outright, the same family of refusal as the one from trigger
 * context that WorkItemInboundQueueable was created to escape. So this class does no callout,
 * no parsing and no adapter work: it selects, counts, and hands the batch to
 * WorkItemInboundQueueable, which is the one place inbound callouts happen on either path.
 * Adding a second place would mean two answers to "where does inbound call out".
 *
 * AND WHY THAT FIXES THE CREDENTIAL PROBLEM AS A SIDE EFFECT.
 *
 * An async job runs as the user who started it, and a Queueable inherits the user of whatever
 * enqueued it. The platform event subscriber runs as Automated Process, which cannot be granted
 * the Asana_Token-PAT1 external credential principal at all - the assignment is refused with
 * "user license doesn't match" - so for a while every Asana delivery failed on
 * "We couldn't access the credential(s)" with nothing but an Integration_Log__c row to say so.
 * A scheduled job runs as whoever scheduled it. Schedule this as a user who holds the grant and
 * the callout simply works, which makes the sweeper a genuine fallback for that whole class of
 * failure rather than only a tidier.
 *
 * LIMITS THIS RESPECTS, EACH OF WHICH BINDS SOMEWHERE DIFFERENT.
 *
 *   - 100 scheduled Apex jobs per org, and FOUR of them go on this. Salesforce cron rejects a
 *     list in the seconds or minutes field - `0 0,15,30,45 * * * ?` throws
 *     "Seconds and minutes must be specified as integers" - so sub-hourly scheduling is four
 *     separate jobs at :00, :15, :30 and :45, not one expression. That is the platform's idiom,
 *     not a workaround. Four of a hundred slots is cheap; the alternative is a single hourly job
 *     and up to an hour before the fallback notices the fast path has stopped.
 *   - 50 queueables enqueued per transaction. This enqueues one.
 *   - BATCH_SIZE is 200, matching the batch size WorkItemInboundProcessor is tested against.
 *     Asana is fetched ten tasks to a request, so 200 deliveries is at worst 20 of the 100
 *     callouts a transaction is allowed.
 *   - The SOQL LIMIT is what keeps the query bounded as the table grows; combined with the
 *     retry ceiling, the Pending set has a maximum size instead of a trend.
 *   - QUIET_MINUTES keeps this off deliveries the platform event path is still working on.
 *     Without it the sweeper would race the fast path on every fresh webhook and both would
 *     process the same row.
 *
 * The schedule is org state and is not in source control. It does not survive a new scratch org;
 * scripts/apex/schedule-inbound-sweeper.apex re-creates it, and docs/handoff.md says so.
 */
public without sharing class WorkItemInboundSweeper implements Schedulable {
  /** Matches the batch size WorkItemInboundProcessor is tested against. */
  @TestVisible
  private static final Integer BATCH_SIZE = 200;

  /**
   * How many sweeps a delivery gets before it is retired.
   *
   * Three, because the failures worth retrying here are transient by nature - a callout budget
   * exhausted by a large batch, a job that died mid-transaction. A delivery that has failed to
   * produce a change three times over is not going to produce one on the fourth, and in practice
   * most rows that reach the ceiling are the story events that were never eligible to begin with.
   */
  @TestVisible
  private static final Integer MAX_ATTEMPTS = 3;

  /**
   * How long a delivery is left to the fast path before this class touches it.
   *
   * The platform event subscriber usually applies a delivery within seconds. Sweeping anything
   * newer than this would mean two transactions holding the same row, both of which would read
   * it as Pending and both of which would apply it.
   */
  @TestVisible
  private static final Integer QUIET_MINUTES = 5;

  public void execute(SchedulableContext context) {
    sweep();
  }

  /**
   * One pass. Separate from execute so a test - and an operator with anonymous Apex - can run a
   * sweep without standing up a schedule.
   *
   * @return how many deliveries were handed to the queueable. Retired rows are not counted:
   *         nothing was attempted for them.
   */
  public static Integer sweep() {
    Datetime cutoff = System.now().addMinutes(-QUIET_MINUTES);

    List<Webhook_Event__c> stale = [
      SELECT Id, Retry_Count__c, Error_Message__c
      FROM Webhook_Event__c
      WHERE
        Processing_Status__c = :DeliveryStatus.PENDING
        AND Signature_Valid__c = TRUE
        AND Received_At__c <= :cutoff
      ORDER BY Received_At__c ASC
      LIMIT :BATCH_SIZE
    ];
    if (stale.isEmpty()) {
      return 0;
    }

    List<Webhook_Event__c> updates = new List<Webhook_Event__c>();
    Set<Id> toProcess = new Set<Id>();

    for (Webhook_Event__c row : stale) {
      // Null rather than zero on every row written before this class existed - Retry_Count__c
      // was declared in build 02 and left inert until now.
      Integer attempts = row.Retry_Count__c == null
        ? 0
        : row.Retry_Count__c.intValue();

      if (attempts >= MAX_ATTEMPTS) {
        // Ignored, not Failed. Nothing went wrong: the delivery was understood and deliberately
        // not applied, which is exactly what that status has meant since build 02. Calling it
        // Failed would fill the failure view with routine Asana comment traffic and hide the
        // deliveries that really did break.
        updates.add(
          new Webhook_Event__c(
            Id = row.Id,
            Processing_Status__c = DeliveryStatus.IGNORED,
            // The retirement reason as a value, so a retention rule does not have to
            // string-match the note below to tell this apart from a superseded delivery.
            Ignore_Reason__c = IgnoreReason.NOT_APPLICABLE,
            Error_Message__c = retirementNote(row, attempts)
          )
        );
        continue;
      }

      updates.add(
        new Webhook_Event__c(Id = row.Id, Retry_Count__c = attempts + 1)
      );
      toProcess.add(row.Id);
    }

    // Before the enqueue, deliberately. The count has to be durable even if the job never runs,
    // or a queueable that dies takes its own retry budget with it and the row is swept for ever.
    // Legal here in a way it would not be inside the queueable: System.enqueueJob is not a
    // callout, and the job is a separate transaction, so this DML cannot strand the adapter's
    // fetch on "uncommitted work pending".
    update updates;

    if (toProcess.isEmpty()) {
      return 0;
    }
    System.enqueueJob(new WorkItemInboundQueueable(toProcess));
    return toProcess.size();
  }

  /**
   * Why a row was retired, appended to whatever the processor already said about it.
   *
   * The existing message is kept because it is usually the useful half - the adapter's own note
   * about what it could not do with the payload. This adds the fact that nobody will try again.
   */
  private static String retirementNote(Webhook_Event__c row, Integer attempts) {
    String existing = String.isBlank(row.Error_Message__c)
      ? ''
      : row.Error_Message__c + ' | ';
    return Strings.truncate(
      existing +
        'Retired by WorkItemInboundSweeper after ' +
        attempts +
        ' attempts produced no change. Most often a delivery about a resource the adapter ' +
        'does not handle, such as an Asana story event.',
      Webhook_Event__c.Error_Message__c.getDescribe().getLength()
    );
  }
}
