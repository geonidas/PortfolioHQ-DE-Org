/**
 * The rule no other test in this project exercises: the inbound entry point is a TRIGGER, and
 * Apex refuses a callout made from one.
 *
 * Every other inbound test calls WorkItemInboundProcessor.process directly, which is a perfectly
 * good way to test what processing does and a useless way to find out whether processing can run
 * where it actually runs. It could not. The first live Asana delivery returned
 * "Callout from triggers are currently not supported", left the delivery staged, and created
 * nothing - while the whole suite stayed green.
 */
@IsTest
private class WorkItemInboundQueueableTest {
  private static final String TASK_GID = '1210000000000077';

  private static Webhook_Event__c delivery() {
    return new Webhook_Event__c(
      Source_System__c = ExternalSystem.ASANA,
      Received_At__c = System.now(),
      Signature_Valid__c = true,
      Processing_Status__c = DeliveryStatus.PENDING,
      Raw_Payload__c = AsanaPayloadFactory.taskEvent(TASK_GID)
    );
  }

  @IsTest
  static void theSubscriberEnqueuesRatherThanApplyingInline() {
    // The regression test. handle() runs in trigger context, so it must not do the work itself -
    // whatever it hands off to is free to call out, and it is not.
    Webhook_Event__c event = delivery();
    insert event;

    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    WorkItemInboundProcessor.handle(
      new List<Webhook_Event_Received__e>{
        new Webhook_Event_Received__e(Webhook_Event_Id__c = event.Id)
      }
    );
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      before + 1,
      after,
      'The subscriber hands the batch to a queueable. Applying it inline would work for Jira, ' +
      'which calls out for nothing, and fail for every system that hydrates.'
    );
  }

  @IsTest
  static void anEmptyOrUnusableBatchEnqueuesNothing() {
    Test.startTest();
    Integer before = Limits.getQueueableJobs();
    WorkItemInboundProcessor.handle(new List<Webhook_Event_Received__e>());
    WorkItemInboundProcessor.handle(
      new List<Webhook_Event_Received__e>{
        new Webhook_Event_Received__e(Webhook_Event_Id__c = null)
      }
    );
    Integer after = Limits.getQueueableJobs();
    Test.stopTest();

    Assert.areEqual(
      before,
      after,
      'Nothing to apply is not worth a job, and an event naming no delivery is not a delivery.'
    );
  }

  /**
   * The queueable doing the work, WITH a callout - which is the whole reason it exists.
   *
   * The DML that stages the delivery happens before the job is enqueued, and the callout happens
   * inside it. That ordering is legal precisely because the queueable is a fresh transaction;
   * the same two statements in one transaction throw "uncommitted work pending".
   */
  @IsTest
  static void theQueueableAppliesADeliveryAndIsAllowedToCallOut() {
    FieldMappingService.reset();
    FieldMappingService.injected = AsanaPayloadFactory.statusMappings();
    AsanaAdapter.injectedProjectGids = new Set<String>{
      AsanaPayloadFactory.PROJECT_GID
    };
    Test.setMock(
      HttpCalloutMock.class,
      new AsanaCalloutMock(
        AsanaCalloutMock.Scenario.BATCH_OK,
        new Map<String, String>{
          TASK_GID => AsanaPayloadFactory.task(
            TASK_GID,
            'Deep Work by Cal Newport',
            AsanaPayloadFactory.SECTION_IN_PROGRESS,
            'In progress',
            false,
            Datetime.newInstanceGmt(2026, 9, 21, 12, 0, 0)
          )
        }
      )
    );

    Webhook_Event__c event = delivery();
    insert event;

    Test.startTest();
    System.enqueueJob(new WorkItemInboundQueueable(new Set<Id>{ event.Id }));
    Test.stopTest();

    List<Work_Item__c> created = [
      SELECT Title__c, Status__c, External_Id__c
      FROM Work_Item__c
      WHERE External_Id__c = :'asana:' + TASK_GID
    ];
    Assert.areEqual(
      1,
      created.size(),
      'The delivery was hydrated and applied. Before the fix this ran in trigger context and ' +
      'threw before it could fetch anything.'
    );
    Assert.areEqual('Deep Work by Cal Newport', created[0].Title__c);
    Assert.areEqual(
      WorkItemStatus.IN_PROGRESS,
      created[0].Status__c,
      'And the section mapped, which only happens if hydration actually returned a task.'
    );
    Assert.areEqual(
      DeliveryStatus.PROCESSED,
      [SELECT Processing_Status__c FROM Webhook_Event__c WHERE Id = :event.Id]
      .Processing_Status__c,
      'And the delivery was retired rather than left staged.'
    );
  }

  @IsTest
  static void aDeliveryAlreadyRetiredIsNotAppliedTwice() {
    // The queueable re-reads rather than carrying rows across, so a delivery retired between the
    // publish and the job running is skipped rather than applied a second time.
    Webhook_Event__c event = delivery();
    event.Processing_Status__c = DeliveryStatus.PROCESSED;
    insert event;

    Test.startTest();
    System.enqueueJob(new WorkItemInboundQueueable(new Set<Id>{ event.Id }));
    Test.stopTest();

    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Work_Item__c
        WHERE External_System__c = :ExternalSystem.ASANA
      ],
      'Nothing was applied: the row was no longer Pending when the job ran.'
    );
  }
}
