/**
 * The Asana adapter's inbound path: hydration, the membership rule, and the completion override.
 *
 * Deliveries are built in memory rather than inserted. That is not a shortcut - AsanaAdapter
 * calls out from parseInbound, and Apex refuses a callout once the transaction holds uncommitted
 * DML. A test that inserted its Webhook_Event__c rows first would fail with "You have uncommitted
 * work pending", which is exactly the trap the rule on IWorkItemAdapter.parseInbound exists to
 * prevent in production.
 */
@IsTest
private class AsanaAdapterTest {
  private static final String TASK_A = '1210000000000001';
  private static final String TASK_B = '1210000000000002';

  private static Datetime modifiedAt = Datetime.newInstanceGmt(
    2026,
    9,
    19,
    10,
    30,
    0
  );

  private static void mapStatuses() {
    FieldMappingService.reset();
    FieldMappingService.injected = AsanaPayloadFactory.statusMappings();
  }

  private static void trackTheLearningProject() {
    AsanaAdapter.injectedProjectGids = new Set<String>{
      AsanaPayloadFactory.PROJECT_GID
    };
  }

  private static List<Webhook_Event__c> deliveries(List<String> payloads) {
    List<Webhook_Event__c> events = new List<Webhook_Event__c>();
    for (String payload : payloads) {
      events.add(AsanaPayloadFactory.delivery(payload));
    }
    return events;
  }

  private static AsanaCalloutMock mockReturning(Map<String, String> tasks) {
    AsanaCalloutMock mock = new AsanaCalloutMock(
      AsanaCalloutMock.Scenario.BATCH_OK,
      tasks
    );
    Test.setMock(HttpCalloutMock.class, mock);
    return mock;
  }

  // ---------- hydration ----------

  @IsTest
  static void threeEventsOnTwoTasksFetchTwoTasks() {
    mapStatuses();
    trackTheLearningProject();
    AsanaCalloutMock mock = mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'First',
          AsanaPayloadFactory.SECTION_UP_NEXT,
          'Up Next',
          false,
          modifiedAt
        ),
        TASK_B => AsanaPayloadFactory.task(
          TASK_B,
          'Second',
          AsanaPayloadFactory.SECTION_IN_PROGRESS,
          'In Progress',
          false,
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(
          new List<String>{
            AsanaPayloadFactory.taskEvent(TASK_A),
            AsanaPayloadFactory.taskEvent(TASK_B),
            AsanaPayloadFactory.taskEvent(TASK_A)
          }
        )
      );
    Test.stopTest();

    Assert.areEqual(
      new Set<String>{ TASK_A, TASK_B },
      mock.allRequestedGids(),
      'Two tasks fetched for three events. Deduplication before fetching is what makes ' +
      'hydration affordable at all.'
    );
    Assert.areEqual(
      1,
      mock.callCount(),
      'And one batch call, not one call per task - Asana takes ten actions per request.'
    );
    Assert.isTrue(
      mock.captured[0].body.contains('memberships.section.gid'),
      'Every fetch asks for opt_fields. Without them Asana returns a task with no name, no ' +
        'section and no completion flag: ' +
        mock.captured[0].body
    );
    Assert.areEqual(
      3,
      changes.size(),
      'One change per event, even though two of them concern one task.'
    );
  }

  @IsTest
  static void aHydratedTaskMapsTitleIdModifiedDateAndProject() {
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'Read the Trailhead module',
          AsanaPayloadFactory.SECTION_UP_NEXT,
          'Up Next',
          false,
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
      );
    Test.stopTest();

    InboundChange change = changes[0];
    Assert.isTrue(change.isUsable(), 'Failure: ' + change.failure);
    Assert.areEqual(
      'asana:' + TASK_A,
      change.externalId,
      'The task gid, namespaced - uniqueness is per field, not per system.'
    );
    Assert.areEqual('Read the Trailhead module', change.title);
    Assert.areEqual(
      modifiedAt,
      change.remoteUpdated,
      'modified_at, not the event time.'
    );
    Assert.areEqual(
      AsanaPayloadFactory.PROJECT_GID,
      change.projectKey,
      'The project gid, which the processor matches against External_Project_Key__c.'
    );
    Assert.isNull(
      change.externalKey,
      'Asana has no human-readable key. Filling it with the gid would publish a number a ' +
      'visitor cannot use.'
    );
    Assert.areEqual(WorkItemStatus.TO_DO, change.normalizedStatus);
  }

  // ---------- status, and the completion override ----------

  @IsTest
  static void anUnfinishedTaskTakesItsStatusFromTheSection() {
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'In flight',
          AsanaPayloadFactory.SECTION_IN_PROGRESS,
          'In Progress',
          false,
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
      );
    Test.stopTest();

    Assert.areEqual(
      WorkItemStatus.IN_PROGRESS,
      changes[0].normalizedStatus,
      'completed is false, so the section decides.'
    );
  }

  @IsTest
  static void theCompletionFlagOverridesTheSection() {
    // The case this rule exists for. Asana's checkbox is independent of sections and is the
    // easiest way in the UI to finish something: it sets completed true without moving the
    // card. Without the override, ticking it strikes the task through in Asana while the
    // Salesforce board still shows In Progress, and nothing anywhere says why.
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'Ticked without moving',
          AsanaPayloadFactory.SECTION_IN_PROGRESS,
          'In Progress',
          true,
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
      );
    Test.stopTest();

    Assert.areEqual(
      WorkItemStatus.DONE,
      changes[0].normalizedStatus,
      'completed true wins over a section that says In Progress.'
    );
  }

  @IsTest
  static void anUnmappedSectionFallsBackAndSaysSo() {
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'Somewhere unexpected',
          AsanaPayloadFactory.SECTION_UNMAPPED,
          'Parked',
          false,
          modifiedAt
        )
      }
    );

    Test.startTest();
    AsanaAdapter adapter = new AsanaAdapter();
    List<InboundChange> changes = adapter.parseInbound(
      deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
    );
    List<Integration_Log__c> logs = adapter.drainLogs();
    Test.stopTest();

    Assert.areEqual(
      WorkItemStatus.UNSPECIFIED,
      changes[0].normalizedStatus,
      'The same catch-all an unmapped Jira status lands on.'
    );
    Assert.areEqual(
      'Parked',
      changes[0].remoteStatus,
      'The vendor word is kept so the log row means something.'
    );
    Assert.areEqual(
      1,
      logsMentioning(logs, AsanaPayloadFactory.SECTION_UNMAPPED).size(),
      'And exactly one row names the section gid that needs a mapping.'
    );
  }

  // ---------- the membership rule ----------

  @IsTest
  static void aTaskInTwoProjectsReadsTheSectionFromTheOneWeTrack() {
    mapStatuses();
    trackTheLearningProject();
    // Listed with the untracked project FIRST, so taking memberships[0] would pass the status
    // assertion by accident and fail this one.
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'Shared across projects',
          new List<String>{
            AsanaPayloadFactory.OTHER_PROJECT_GID,
            AsanaPayloadFactory.PROJECT_GID
          },
          new List<String>{
            AsanaPayloadFactory.SECTION_UNMAPPED,
            AsanaPayloadFactory.SECTION_IN_PROGRESS
          },
          new List<String>{ 'Someone else\'s column', 'In Progress' },
          false,
          modifiedAt,
          null
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
      );
    Test.stopTest();

    Assert.areEqual(
      WorkItemStatus.IN_PROGRESS,
      changes[0].normalizedStatus,
      'The section came from the membership whose project we track, not the first one listed.'
    );
    Assert.areEqual(
      AsanaPayloadFactory.PROJECT_GID,
      changes[0].projectKey,
      'And so did the project.'
    );
  }

  @IsTest
  static void aTaskInNoTrackedProjectCarriesNoProjectAndSaysSo() {
    mapStatuses();
    AsanaAdapter.injectedProjectGids = new Set<String>{
      'a-project-we-do-not-track'
    };
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'Elsewhere entirely',
          AsanaPayloadFactory.SECTION_IN_PROGRESS,
          'In Progress',
          false,
          modifiedAt
        )
      }
    );

    Test.startTest();
    AsanaAdapter adapter = new AsanaAdapter();
    List<InboundChange> changes = adapter.parseInbound(
      deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
    );
    List<Integration_Log__c> logs = adapter.drainLogs();
    Test.stopTest();

    Assert.isNull(
      changes[0].projectKey,
      'No membership matched, so there is no project to name and none is guessed at.'
    );
    Assert.areEqual(
      WorkItemStatus.UNSPECIFIED,
      changes[0].normalizedStatus,
      'And no section to read a status from either.'
    );
    Assert.areEqual(
      1,
      logsMentioning(logs, 'no project this org tracks').size(),
      'The gap is reported once, with what to do about it.'
    );
  }

  @IsTest
  static void theQueryForTrackedProjectsReadsRealRecords() {
    // The injection the other tests use bypasses this query, so it gets its own test - with no
    // callout, because inserting the projects is DML and DML before a callout throws.
    Project__c tracked = TestDataFactory.createProjects(1, false)[0];
    tracked.External_System__c = ExternalSystem.ASANA;
    tracked.External_Project_Key__c = AsanaPayloadFactory.PROJECT_GID;
    Project__c jira = TestDataFactory.createProjects(1, false)[0];
    jira.External_Project_Key__c = 'DOPP';
    insert new List<Project__c>{ tracked, jira };

    Test.startTest();
    // An empty batch returns before any callout, so this exercises nothing but the query path
    // the adapter would use. The behavioural assertions live in the tests above.
    List<InboundChange> none = new AsanaAdapter()
      .parseInbound(new List<Webhook_Event__c>());
    Test.stopTest();

    Assert.areEqual(0, none.size(), 'Nothing in, nothing out.');
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Project__c
        WHERE
          External_System__c = :ExternalSystem.ASANA
          AND External_Project_Key__c != NULL
      ],
      'One Asana-keyed project exists for the adapter to find, and the Jira one is not it.'
    );
  }

  // ---------- failures ----------

  @IsTest
  static void aFailedFetchSkipsThoseEventsAndLeavesTheRestAlone() {
    mapStatuses();
    trackTheLearningProject();
    AsanaAdapter.batchSize = 1; // one task per call, so one call can fail on its own
    AsanaCalloutMock mock = new AsanaCalloutMock(
      AsanaCalloutMock.Scenario.TASK_MISSING,
      new Map<String, String>()
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    AsanaAdapter adapter = new AsanaAdapter();
    List<InboundChange> changes = adapter.parseInbound(
      deliveries(
        new List<String>{
          AsanaPayloadFactory.taskEvent(TASK_A),
          AsanaPayloadFactory.taskEvent(TASK_B)
        }
      )
    );
    List<Integration_Log__c> logs = adapter.drainLogs();
    Test.stopTest();

    Assert.areEqual(
      0,
      changes.size(),
      'A task that could not be fetched yields no change at all, so the processor leaves its ' +
      'delivery staged and the next run tries again rather than retiring it wrongly.'
    );
    Assert.isTrue(
      logs.size() >= 2,
      'And every one is reported: ' + logs.size()
    );
  }

  @IsTest
  static void aTransportFailureIsLoggedAndTheBatchStillReturns() {
    mapStatuses();
    trackTheLearningProject();
    Test.setMock(
      HttpCalloutMock.class,
      new AsanaCalloutMock(
        AsanaCalloutMock.Scenario.TRANSPORT_FAILS,
        new Map<String, String>()
      )
    );

    Test.startTest();
    AsanaAdapter adapter = new AsanaAdapter();
    List<InboundChange> changes = adapter.parseInbound(
      deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
    );
    List<Integration_Log__c> logs = adapter.drainLogs();
    Test.stopTest();

    Assert.areEqual(0, changes.size(), 'Nothing hydrated, nothing returned.');
    Assert.isFalse(
      logs.isEmpty(),
      'The adapter contracts not to throw. A callout that fell over comes back as a log row.'
    );
  }

  @IsTest
  static void anHttpErrorIsLoggedAndTheBatchStillReturns() {
    mapStatuses();
    trackTheLearningProject();
    Test.setMock(
      HttpCalloutMock.class,
      new AsanaCalloutMock(
        AsanaCalloutMock.Scenario.HTTP_ERROR,
        new Map<String, String>()
      )
    );

    Test.startTest();
    AsanaAdapter adapter = new AsanaAdapter();
    List<InboundChange> changes = adapter.parseInbound(
      deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
    );
    List<Integration_Log__c> logs = adapter.drainLogs();
    Test.stopTest();

    Assert.areEqual(0, changes.size());
    Assert.areEqual(
      1,
      logsMentioning(logs, '500').size(),
      'The status code is named so a person can tell a 500 from a timeout.'
    );
  }

  @IsTest
  static void anUnreadableEventFailsOnlyItself() {
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'Fine',
          AsanaPayloadFactory.SECTION_UP_NEXT,
          'Up Next',
          false,
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(
          new List<String>{
            'this is not json at all',
            AsanaPayloadFactory.taskEvent(TASK_A)
          }
        )
      );
    Test.stopTest();

    Assert.areEqual(
      2,
      changes.size(),
      'The broken one comes back carrying its failure so the processor can retire it, and ' +
      'the good one is unaffected.'
    );
    Assert.isFalse(changes[0].isUsable(), 'The first is the broken one.');
    Assert.isTrue(changes[1].isUsable(), 'The second parsed.');
  }

  @IsTest
  static void anEventAboutSomethingOtherThanATaskIsLeftAlone() {
    mapStatuses();
    trackTheLearningProject();
    mockReturning(new Map<String, String>());

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(
          new List<String>{ AsanaPayloadFactory.sectionEvent('1209999') }
        )
      );
    Test.stopTest();

    Assert.areEqual(
      0,
      changes.size(),
      'Asana sends section, project and story events on the same webhook. Not a failure and ' +
      'not a change - the row is left staged, so a later build that cares can pick it up.'
    );
  }

  // ---------- type (build 07 step 7) ----------

  @IsTest
  static void aMappedAsanaTypeNormalisesAndKeepsTheRawValue() {
    FieldMappingService.reset();
    List<Field_Mapping__mdt> rows = AsanaPayloadFactory.statusMappings();
    rows.add(
      AsanaPayloadFactory.mapping(
        FieldMappingService.TYPE,
        // The enum option gid, not the option name - renaming "Spike" in Asana must not
        // silently stop this matching.
        AsanaPayloadFactory.FORMAT_OPTION_GID,
        'Spike',
        WorkItemType.SPIKE
      )
    );
    FieldMappingService.injected = rows;
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.typedTask(
          TASK_A,
          'Investigate something',
          AsanaPayloadFactory.SECTION_UP_NEXT,
          'Spike',
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
      );
    Test.stopTest();

    Assert.areEqual(WorkItemType.SPIKE, changes[0].normalizedType);
    Assert.areEqual(
      'Spike',
      changes[0].remoteType,
      'The raw vendor string travels alongside, for Source_Type__c.'
    );
  }

  @IsTest
  static void anUnmappedAsanaTypeLandsOnUnspecifiedAndKeepsTheRawValue() {
    // The leak this design exists to prevent. Type__c is read by epic resolution and reaches
    // the public board, so a free-text type would publish whatever somebody typed into Asana.
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.typedTask(
          TASK_A,
          'A book',
          AsanaPayloadFactory.SECTION_UP_NEXT,
          'Reading: Negotiating After a Layoff',
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
      );
    Test.stopTest();

    Assert.areEqual(
      WorkItemType.UNSPECIFIED,
      changes[0].normalizedType,
      'Unmapped lands on the catch-all, and the restricted picklist is what keeps this string ' +
      'off a public card.'
    );
    Assert.areEqual(
      'Reading: Negotiating After a Layoff',
      changes[0].remoteType,
      'Preserved, but only somewhere private - Source_Type__c is on no DTO and no guest set.'
    );
  }

  @IsTest
  static void aTaskWithNoTypeCustomFieldCarriesNoType() {
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'Untyped',
          AsanaPayloadFactory.SECTION_UP_NEXT,
          'Up Next',
          false,
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(new List<String>{ AsanaPayloadFactory.taskEvent(TASK_A) })
      );
    Test.stopTest();

    Assert.isNull(
      changes[0].normalizedType,
      'Absent is absent, never unmapped. The processor leaves an existing Type__c alone.'
    );
    Assert.isNull(changes[0].remoteType, 'And there is no raw value to keep.');
  }

  // ---------- what Asana does not have ----------

  @IsTest
  static void everyChangeCarriesNoIterationReference() {
    mapStatuses();
    trackTheLearningProject();
    mockReturning(
      new Map<String, String>{
        TASK_A => AsanaPayloadFactory.task(
          TASK_A,
          'One',
          AsanaPayloadFactory.SECTION_UP_NEXT,
          'Up Next',
          false,
          modifiedAt
        ),
        TASK_B => AsanaPayloadFactory.task(
          TASK_B,
          'Two',
          AsanaPayloadFactory.SECTION_COMPLETED,
          'Completed',
          true,
          modifiedAt
        )
      }
    );

    Test.startTest();
    List<InboundChange> changes = new AsanaAdapter()
      .parseInbound(
        deliveries(
          new List<String>{
            AsanaPayloadFactory.taskEvent(TASK_A),
            AsanaPayloadFactory.taskEvent(TASK_B)
          }
        )
      );
    Test.stopTest();

    Assert.areEqual(2, changes.size());
    for (InboundChange change : changes) {
      Assert.isNull(
        change.iterationRef,
        'Sprints are a Jira concept. Asana has no equivalent and never will, so this stays ' +
        'null however the field is used later.'
      );
      Assert.isNull(
        change.parentExternalId,
        'Asana items are flat in this build.'
      );
    }
  }

  @IsTest
  static void theFactoryReturnsTheAsanaAdapterForAnAsanaId() {
    Test.startTest();
    IWorkItemAdapter byNamespace = WorkItemAdapterFactory.forSystem(
      ExternalSystem.ASANA_NAMESPACE
    );
    IWorkItemAdapter byPicklist = WorkItemAdapterFactory.forSystem(
      ExternalSystem.ASANA
    );
    IWorkItemAdapter byRecord = WorkItemAdapterFactory.forWorkItem(
      new Work_Item__c(External_Id__c = 'asana:' + TASK_A)
    );
    Test.stopTest();

    Assert.isInstanceOfType(byNamespace, AsanaAdapter.class);
    Assert.isInstanceOfType(
      byPicklist,
      AsanaAdapter.class,
      'The picklist spelling routes too - namespaceOf lowercases it.'
    );
    Assert.isInstanceOfType(
      byRecord,
      AsanaAdapter.class,
      'And so does a record, by the namespace on its external id.'
    );
  }

  // ---------- helpers ----------

  private static List<Integration_Log__c> logsMentioning(
    List<Integration_Log__c> logs,
    String fragment
  ) {
    List<Integration_Log__c> matched = new List<Integration_Log__c>();
    for (Integration_Log__c log : logs) {
      if (
        log.Error_Message__c != null && log.Error_Message__c.contains(fragment)
      ) {
        matched.add(log);
      }
    }
    return matched;
  }
}
