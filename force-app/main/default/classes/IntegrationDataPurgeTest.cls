/**
 * The purge's two halves: it holds each table at the cap, and it refuses to take the rows that
 * are not history.
 *
 * CreatedDate cannot be assigned on insert, and rows inserted in one DML share a timestamp to the
 * millisecond - which would make every row a tie and every assertion here vacuous. Test.setCreatedDate
 * exists for exactly this and is what spreads them out.
 */
@IsTest
private class IntegrationDataPurgeTest {
  private static final Integer KEEP = 50;

  /**
   * `count` webhook events, one per minute going back from now, newest first.
   *
   * @return the ids in the order they were aged, newest at index 0.
   */
  private static List<Id> agedEvents(Integer count, String status) {
    List<Webhook_Event__c> rows = new List<Webhook_Event__c>();
    for (Integer i = 0; i < count; i++) {
      rows.add(
        new Webhook_Event__c(
          Source_System__c = ExternalSystem.ASANA,
          Received_At__c = System.now().addMinutes(-i),
          Signature_Valid__c = true,
          Processing_Status__c = status,
          Raw_Payload__c = '{"gid":"' + i + '"}'
        )
      );
    }
    insert rows;

    List<Id> ids = new List<Id>();
    for (Integer i = 0; i < rows.size(); i++) {
      Test.setCreatedDate(rows[i].Id, System.now().addMinutes(-i));
      ids.add(rows[i].Id);
    }
    return ids;
  }

  private static void agedLogs(Integer count) {
    List<Integration_Log__c> rows = new List<Integration_Log__c>();
    for (Integer i = 0; i < count; i++) {
      rows.add(
        new Integration_Log__c(
          Direction__c = LogDirection.INBOUND,
          Is_Success__c = true,
          Error_Message__c = 'row ' + i
        )
      );
    }
    insert rows;
    for (Integer i = 0; i < rows.size(); i++) {
      Test.setCreatedDate(rows[i].Id, System.now().addMinutes(-i));
    }
  }

  private static Integer countEvents() {
    return [SELECT COUNT() FROM Webhook_Event__c];
  }

  // ---------- the cap ----------

  @IsTest
  static void aTableOverTheCapIsCutBackToIt() {
    agedEvents(KEEP + 20, DeliveryStatus.PROCESSED);

    Test.startTest();
    Map<String, Integer> removed = IntegrationDataPurge.purge();
    Test.stopTest();

    Assert.areEqual(
      20,
      removed.get('Webhook_Event__c'),
      'The 20 oldest went and nothing else did.'
    );
    Assert.areEqual(
      KEEP,
      countEvents(),
      'Both tables were flagged as unbounded as far back as build 03. This is the ceiling.'
    );
  }

  @IsTest
  static void theSurvivorsAreTheMostRecentOnes() {
    // Not just "50 remain" - the RIGHT 50. A purge that kept the oldest would satisfy a count
    // assertion perfectly and be exactly backwards.
    List<Id> newestFirst = agedEvents(KEEP + 10, DeliveryStatus.PROCESSED);

    Test.startTest();
    IntegrationDataPurge.purge();
    Test.stopTest();

    Set<Id> survived = new Map<Id, Webhook_Event__c>(
        [SELECT Id FROM Webhook_Event__c]
      )
      .keySet();
    Assert.isTrue(
      survived.contains(newestFirst[0]),
      'The newest row survived.'
    );
    Assert.isTrue(
      survived.contains(newestFirst[KEEP - 1]),
      'And so did the 50th, which is the boundary itself.'
    );
    Assert.isFalse(
      survived.contains(newestFirst[KEEP]),
      'The 51st did not. Off by one here silently keeps or drops a row every night.'
    );
  }

  @IsTest
  static void aTableUnderTheCapIsLeftAlone() {
    agedEvents(10, DeliveryStatus.PROCESSED);

    Test.startTest();
    Map<String, Integer> removed = IntegrationDataPurge.purge();
    Test.stopTest();

    Assert.areEqual(0, removed.get('Webhook_Event__c'), 'Nothing to do.');
    Assert.areEqual(
      10,
      countEvents(),
      'A half-populated table must read as "nothing to do", not as "delete everything" - which ' +
      'is what an empty boundary query would mean if it were read the other way.'
    );
  }

  @IsTest
  static void anEmptyTableIsNotAnError() {
    Test.startTest();
    Map<String, Integer> removed = IntegrationDataPurge.purge();
    Test.stopTest();

    Assert.areEqual(0, removed.get('Webhook_Event__c'));
    Assert.areEqual(0, removed.get('Integration_Log__c'));
  }

  // ---------- what it will not take ----------

  @IsTest
  static void aPendingDeliveryIsKeptHoweverOldItIs() {
    // The case that matters most in exactly the scenario the row count looks worst: if the
    // sweeper stops, Pending rows pile up, and a purge that took them would destroy the backlog
    // and the evidence of the outage together.
    agedEvents(KEEP + 20, DeliveryStatus.PROCESSED);
    List<Id> pending = agedEvents(3, DeliveryStatus.PENDING);
    for (Id eventId : pending) {
      Test.setCreatedDate(eventId, System.now().addDays(-30));
    }

    Test.startTest();
    IntegrationDataPurge.purge();
    Test.stopTest();

    Assert.areEqual(
      3,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE Processing_Status__c = :DeliveryStatus.PENDING
      ],
      'A month old, far past the cutoff, and still here. Pending is work in progress, not ' +
      'history, and deleting one throws away a delivery nobody has applied yet.'
    );
  }

  @IsTest
  static void pendingRowsAreKeptOnTopOfTheCapNotInsteadOfIt() {
    // They are counted for the cutoff and excluded from the delete, so they do not cost a
    // terminal row its place.
    agedEvents(KEEP, DeliveryStatus.PROCESSED);
    agedEvents(5, DeliveryStatus.PENDING);

    Test.startTest();
    IntegrationDataPurge.purge();
    Test.stopTest();

    Assert.areEqual(
      KEEP,
      [
        SELECT COUNT()
        FROM Webhook_Event__c
        WHERE Processing_Status__c != :DeliveryStatus.PENDING
      ],
      'All 50 terminal rows survived.'
    );
  }

  // ---------- the other table ----------

  @IsTest
  static void integrationLogsArePurgedOnTheSamePass() {
    agedLogs(KEEP + 15);

    Test.startTest();
    Map<String, Integer> removed = IntegrationDataPurge.purge();
    Test.stopTest();

    Assert.areEqual(15, removed.get('Integration_Log__c'));
    Assert.areEqual(
      KEEP,
      [SELECT COUNT() FROM Integration_Log__c],
      'A log row is terminal when written, so there is no Pending equivalent to protect here.'
    );
  }

  @IsTest
  static void eachObjectIsCappedIndependently() {
    agedEvents(KEEP + 5, DeliveryStatus.PROCESSED);
    agedLogs(10);

    Test.startTest();
    Map<String, Integer> removed = IntegrationDataPurge.purge();
    Test.stopTest();

    Assert.areEqual(5, removed.get('Webhook_Event__c'));
    Assert.areEqual(
      0,
      removed.get('Integration_Log__c'),
      'One table being over the cap is not a reason to touch the other.'
    );
  }

  // ---------- the schedule ----------

  @IsTest
  static void theScheduledEntryPointRunsAPurge() {
    // Test.stopTest() runs a scheduled job immediately whatever time its cron names, so this is
    // the scheduler's own call into execute() rather than ours.
    agedEvents(KEEP + 3, DeliveryStatus.PROCESSED);

    Test.startTest();
    String jobId = System.schedule(
      'IntegrationDataPurgeTest',
      '0 0 23 * * ?',
      new IntegrationDataPurge()
    );
    Test.stopTest();

    Assert.isNotNull(jobId, 'The class is schedulable.');
    Assert.areEqual(
      KEEP,
      countEvents(),
      'And execute() does a real purge rather than only being a valid entry point.'
    );
  }
}
