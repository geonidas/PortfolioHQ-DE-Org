/**
 * The sweeper's two jobs: retry a stranded delivery, and stop retrying one that never resolves.
 *
 * The second is the one worth testing hardest. A sweeper with no ceiling looks correct in every
 * test that runs it once, and fails in production months later when the Pending set has grown
 * past a governor limit.
 */
@IsTest
private class WorkItemInboundSweeperTest {
  private static final String TASK_GID = '1210000000000091';

  /**
   * A staged delivery, aged past the quiet period unless told otherwise.
   *
   * Received_At__c is writable, which is the only reason these tests can exist - the sweeper
   * keys on it, and a row inserted "now" is invisible to a sweep by design.
   */
  private static Webhook_Event__c staged(Integer minutesOld, Decimal retries) {
    return new Webhook_Event__c(
      Source_System__c = ExternalSystem.ASANA,
      Received_At__c = System.now().addMinutes(-minutesOld),
      Signature_Valid__c = true,
      Processing_Status__c = DeliveryStatus.PENDING,
      Retry_Count__c = retries,
      Raw_Payload__c = AsanaPayloadFactory.taskEvent(TASK_GID)
    );
  }

  private static Webhook_Event__c reread(Id eventId) {
    return [
      SELECT Processing_Status__c, Retry_Count__c, Error_Message__c
      FROM Webhook_Event__c
      WHERE Id = :eventId
    ];
  }

  // ---------- what gets swept ----------

  @IsTest
  static void aStrandedDeliveryIsHandedToTheQueueableAndCounted() {
    Webhook_Event__c event = staged(30, null);
    insert event;

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    Integer swept = WorkItemInboundSweeper.sweep();
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(1, swept, 'One delivery was eligible.');
    Assert.areEqual(
      before + 1,
      after,
      'And it went to WorkItemInboundQueueable rather than being applied here. Scheduled Apex ' +
      'cannot call out, so a sweeper that did the work itself would fail on every Asana row.'
    );
    Assert.areEqual(
      1,
      reread(event.Id).Retry_Count__c,
      'Retry_Count__c was inert from build 02 until this class; the first sweep starts it at 1 ' +
      'from null.'
    );
  }

  @IsTest
  static void aFreshDeliveryIsLeftToTheFastPath() {
    // Inside the quiet period. The platform event subscriber is probably mid-flight on this row,
    // and two transactions both reading it as Pending would both apply it.
    Webhook_Event__c event = staged(1, null);
    insert event;

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    Integer swept = WorkItemInboundSweeper.sweep();
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(0, swept, 'Too new to sweep.');
    Assert.areEqual(before, after, 'And nothing was enqueued against it.');
    Assert.areEqual(
      null,
      reread(event.Id).Retry_Count__c,
      'Untouched, so it keeps its full retry budget for when it is old enough to need one.'
    );
  }

  @IsTest
  static void aDeliveryThatIsNotPendingIsNotSwept() {
    Webhook_Event__c done = staged(30, null);
    done.Processing_Status__c = DeliveryStatus.PROCESSED;
    Webhook_Event__c ignored = staged(30, null);
    ignored.Processing_Status__c = DeliveryStatus.IGNORED;
    insert new List<Webhook_Event__c>{ done, ignored };

    Test.startTest();
    Integer swept = WorkItemInboundSweeper.sweep();
    Test.stopTest();

    Assert.areEqual(
      0,
      swept,
      'Pending is the only state that means "not finished with".'
    );
  }

  @IsTest
  static void aDeliveryWithAnInvalidSignatureIsNeverRetried() {
    // The endpoint records a rejection as a row too. Retrying one would be the sweeper quietly
    // reconsidering a security decision made at the door.
    Webhook_Event__c rejected = staged(30, null);
    rejected.Signature_Valid__c = false;
    insert rejected;

    Test.startTest();
    Integer swept = WorkItemInboundSweeper.sweep();
    Test.stopTest();

    Assert.areEqual(
      0,
      swept,
      'An unverified delivery is not work in progress.'
    );
    Assert.areEqual(
      null,
      reread(rejected.Id).Retry_Count__c,
      'And it is not counted against a budget it can never spend.'
    );
  }

  // ---------- the ceiling ----------

  @IsTest
  static void aDeliveryAtTheCeilingIsRetiredRatherThanRetried() {
    // The whole reason the ceiling exists. An Asana story event resolves to nothing on every
    // pass; without this it would be re-read on every sweep for the life of the org.
    Webhook_Event__c event = staged(30, 3);
    event.Error_Message__c = 'Adapter had nothing to say about this resource.';
    insert event;

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    Integer swept = WorkItemInboundSweeper.sweep();
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(0, swept, 'Nothing was attempted for it.');
    Assert.areEqual(
      before,
      after,
      'And no job was enqueued, which is the point - a retired row costs no callout budget.'
    );

    Webhook_Event__c retired = reread(event.Id);
    Assert.areEqual(
      DeliveryStatus.IGNORED,
      retired.Processing_Status__c,
      'Ignored, not Failed. Nothing went wrong; routine comment traffic must not fill the ' +
      'failure view and hide the deliveries that really did break.'
    );
    Assert.isTrue(
      retired.Error_Message__c.contains('Adapter had nothing to say'),
      'The processor\'s own note is kept - it is usually the useful half: ' +
      retired.Error_Message__c
    );
    Assert.isTrue(
      retired.Error_Message__c.contains('Retired by WorkItemInboundSweeper'),
      'With the fact that nobody will try again appended: ' +
      retired.Error_Message__c
    );
  }

  @IsTest
  static void aDeliveryRetiresAfterExactlyThreeAttempts() {
    // Walked rather than asserted at the boundary, because an off-by-one here is invisible:
    // three sweeps and four both look like "it eventually stops".
    Webhook_Event__c event = staged(30, null);
    insert event;

    Test.startTest();
    for (Integer i = 0; i < 3; i++) {
      WorkItemInboundSweeper.sweep();
      Assert.areEqual(
        DeliveryStatus.PENDING,
        reread(event.Id).Processing_Status__c,
        'Still eligible after ' + (i + 1) + ' of 3 attempts.'
      );
    }
    Integer fourth = WorkItemInboundSweeper.sweep();
    Test.stopTest();

    Assert.areEqual(0, fourth, 'The fourth sweep attempts nothing.');
    Assert.areEqual(
      DeliveryStatus.IGNORED,
      reread(event.Id).Processing_Status__c,
      'It retires it instead.'
    );
  }

  // ---------- bounds and the schedule ----------

  @IsTest
  static void nothingToSweepEnqueuesNothing() {
    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    Integer swept = WorkItemInboundSweeper.sweep();
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(0, swept);
    Assert.areEqual(
      before,
      after,
      'An empty sweep costs one query and no job. It runs every 15 minutes for ever, so the ' +
      'idle case has to be cheap.'
    );
  }

  @IsTest
  static void aLargeBacklogIsBoundedToOneBatchAndOneJob() {
    List<Webhook_Event__c> backlog = new List<Webhook_Event__c>();
    for (Integer i = 0; i < 250; i++) {
      backlog.add(staged(30, null));
    }
    insert backlog;

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    Integer swept = WorkItemInboundSweeper.sweep();
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      200,
      swept,
      'Capped at BATCH_SIZE. The rest wait for the next run rather than pushing this ' +
      'transaction past its callout budget downstream.'
    );
    Assert.areEqual(
      before + 1,
      after,
      'One job for the whole batch, not one per delivery - 250 would blow the 50-queueable ' +
      'ceiling on its own.'
    );
    Assert.areEqual(
      50,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE
          Processing_Status__c = :DeliveryStatus.PENDING
          AND Retry_Count__c = NULL
      ],
      'The 50 not swept are untouched, so the next run finds them with a full budget.'
    );
  }

  @IsTest
  static void theScheduledEntryPointRunsASweep() {
    // Scheduled rather than calling sweep() directly, because execute() is what the cron trigger
    // actually invokes. Test.stopTest() runs a scheduled job immediately whatever time its cron
    // expression names, so the assertion below is the scheduler's own call, not ours - an
    // earlier version of this test also called execute() by hand and swept twice, which is how
    // the double-run showed up.
    Webhook_Event__c event = staged(30, null);
    insert event;

    Test.startTest();
    String jobId = System.schedule(
      'WorkItemInboundSweeperTest',
      '0 0 1 1 1 ? 2099',
      new WorkItemInboundSweeper()
    );
    Test.stopTest();

    Assert.isNotNull(jobId, 'The class is schedulable.');
    Assert.areEqual(
      1,
      reread(event.Id).Retry_Count__c,
      'And the job the scheduler ran did a real sweep, rather than execute() being only a ' +
      'valid entry point that does nothing.'
    );
  }
}
