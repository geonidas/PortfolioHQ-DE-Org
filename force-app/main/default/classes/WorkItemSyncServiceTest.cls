/**
 * Covers orchestration: sync fields, log rows, chunking, and the failure paths that must not
 * take the whole run down with them.
 *
 * Tests that only need the service's behaviour inject a fake adapter rather than mocking HTTP.
 * That is not a shortcut - it is the only way to exercise 200 records, since even mocked callouts
 * count against the 100-per-transaction limit.
 */
@IsTest
private class WorkItemSyncServiceTest {
    /** Records calls and returns a scripted outcome, without touching HTTP. */
    private class FakeAdapter implements IWorkItemAdapter {
        private final SyncResult.Outcome outcome;
        private final Boolean throwInstead;
        private final Boolean emitPoisonLog;
        public Integer calls = 0;

        private FakeAdapter(SyncResult.Outcome outcome) {
            this(outcome, false, false);
        }

        private FakeAdapter(SyncResult.Outcome outcome, Boolean throwInstead, Boolean emitPoisonLog) {
            this.outcome = outcome;
            this.throwInstead = throwInstead;
            this.emitPoisonLog = emitPoisonLog;
        }

        public SyncResult updateStatus(Work_Item__c item, String targetStatus) {
            calls++;
            if (throwInstead) {
                throw new AdapterException('adapter exploded');
            }
            SyncResult result = outcome == SyncResult.Outcome.SUCCESS
                ? SyncResult.success(targetStatus, 204)
                : SyncResult.failure(outcome, 'scripted ' + outcome.name(), 500);
            result.workItemId = item.Id;
            result.externalId = item.External_Id__c;
            return result;
        }

        public List<TransitionOption> fetchAvailableTransitions(String externalId) {
            return new List<TransitionOption>();
        }

        public List<Integration_Log__c> drainLogs() {
            return new List<Integration_Log__c>{
                new Integration_Log__c(
                    Direction__c = emitPoisonLog ? 'Nonsense' : 'Outbound', // restricted picklist
                    HTTP_Method__c = 'POST',
                    Status_Code__c = 204,
                    Duration_ms__c = 5,
                    Is_Success__c = true
                )
            };
        }
    }

    private static List<Work_Item__c> seed(Integer count, String status) {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        List<Work_Item__c> items = TestDataFactory.createWorkItems(count, project.Id, false);
        for (Work_Item__c item : items) {
            item.Status__c = status;
            item.Sync_Status__c = 'Pending';
        }
        insert items;
        return [SELECT Id, External_Id__c, External_System__c, Status__c, Sync_Status__c, Last_Synced__c FROM Work_Item__c];
    }

    // ---------- success ----------

    @IsTest
    static void successMarksSyncedAndStampsLastSynced() {
        List<Work_Item__c> items = seed(3, 'In Progress');
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));

        Test.startTest();
        List<SyncResult> results = WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'Every item should have been attempted.');
        for (Work_Item__c item : [SELECT Sync_Status__c, Last_Synced__c FROM Work_Item__c]) {
            Assert.areEqual('Synced', item.Sync_Status__c, 'A successful push should mark the item synced.');
            Assert.isNotNull(item.Last_Synced__c, 'Last_Synced__c should be stamped on success.');
        }
    }

    @IsTest
    static void successWritesOneLogRowPerCallout() {
        List<Work_Item__c> items = seed(2, 'In Progress');
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));

        Test.startTest();
        WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        List<Integration_Log__c> logs = [
            SELECT HTTP_Method__c, Status_Code__c, Is_Success__c, Work_Item__c
            FROM Integration_Log__c
        ];
        Assert.areEqual(4, logs.size(), 'Two items at two callouts each.');
        for (Integration_Log__c log : logs) {
            Assert.isTrue(log.Is_Success__c, 'All calls succeeded.');
            Assert.isNotNull(log.Work_Item__c, 'Rows should be attributed to their work item.');
        }
    }

    // ---------- failure ----------

    @IsTest
    static void failureMarksFailedAndLeavesLastSyncedAlone() {
        List<Work_Item__c> items = seed(2, 'In Progress');
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED));

        Test.startTest();
        WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        for (Work_Item__c item : [SELECT Sync_Status__c, Last_Synced__c FROM Work_Item__c]) {
            Assert.areEqual('Failed', item.Sync_Status__c, 'A 401 should mark the item failed.');
            Assert.isNull(item.Last_Synced__c, 'Last_Synced__c means "agreed", so a failure must not stamp it.');
        }
    }

    @IsTest
    static void failureWritesBothTheCalloutRowAndAnOutcomeRow() {
        List<Work_Item__c> items = seed(1, 'In Progress');
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED));

        Test.startTest();
        WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        List<Integration_Log__c> calloutRows = [
            SELECT Status_Code__c FROM Integration_Log__c WHERE HTTP_Method__c != NULL
        ];
        List<Integration_Log__c> outcomeRows = [
            SELECT Error_Message__c, Is_Success__c FROM Integration_Log__c WHERE HTTP_Method__c = NULL
        ];
        Assert.areEqual(1, calloutRows.size(), 'The 401 callout should be logged.');
        Assert.areEqual(401, calloutRows[0].Status_Code__c.intValue(), 'With its real status code.');
        // A null HTTP_Method__c is what distinguishes an outcome row from a callout row.
        Assert.areEqual(1, outcomeRows.size(), 'The outcome should be logged separately.');
        Assert.isFalse(outcomeRows[0].Is_Success__c, 'Outcome rows for failures are not successes.');
        Assert.isTrue(
            outcomeRows[0].Error_Message__c.contains('UNAUTHORIZED'),
            'Outcome row should name the outcome: ' + outcomeRows[0].Error_Message__c
        );
    }

    @IsTest
    static void unavailableTransitionIsSurfacedInTheLog() {
        List<Work_Item__c> items = seed(1, 'In Progress');
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.NO_MATCHING_TRANSITION));

        Test.startTest();
        WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        // The GET succeeded, so without an outcome row this failure would be invisible in the log.
        List<Integration_Log__c> outcomeRows = [
            SELECT Error_Message__c FROM Integration_Log__c WHERE HTTP_Method__c = NULL
        ];
        Assert.areEqual(1, outcomeRows.size(), 'A business outcome still has to be logged.');
        Assert.isTrue(
            outcomeRows[0].Error_Message__c.contains('NO_TRANSITION_AVAILABLE'),
            'Should name the outcome: ' + outcomeRows[0].Error_Message__c
        );
        Assert.areEqual('Failed', [SELECT Sync_Status__c FROM Work_Item__c LIMIT 1].Sync_Status__c, 'Not synced.');
    }

    @IsTest
    static void anItemForAnUnsupportedSystemFailsWithoutStoppingTheRest() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        List<Work_Item__c> items = TestDataFactory.createWorkItems(2, project.Id, false);
        items[0].External_Id__c = 'asana:998877'; // no adapter registered
        for (Work_Item__c item : items) {
            item.Status__c = 'In Progress';
            item.Sync_Status__c = 'Pending';
        }
        insert items;
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));

        Test.startTest();
        List<SyncResult> results = WorkItemSyncService.syncStatuses(
            [SELECT Id, External_Id__c, Status__c, Sync_Status__c FROM Work_Item__c ORDER BY External_Id__c]
        );
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Both items should produce a result.');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
            'The Jira item should still have synced.'
        );
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Failed'],
            'The unsupported item should have failed on its own.'
        );
    }

    @IsTest
    static void anUnexpectedAdapterExceptionIsContainedPerItem() {
        List<Work_Item__c> items = seed(3, 'In Progress');
        WorkItemAdapterFactory.injected = new FakeAdapter(SyncResult.Outcome.SUCCESS, true, false);

        Test.startTest();
        List<SyncResult> results = WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'One bad item must not strand the others.');
        for (SyncResult result : results) {
            Assert.areEqual(SyncResult.Outcome.CALLOUT_FAILED, result.outcome, 'Should be caught and classified.');
        }
        Assert.areEqual(3, [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Failed'], 'All marked failed.');
    }

    @IsTest
    static void aLoggingFailureDoesNotBreakTheSync() {
        List<Work_Item__c> items = seed(2, 'In Progress');
        // Direction__c is a restricted picklist, so this row cannot be inserted.
        WorkItemAdapterFactory.injected = new FakeAdapter(SyncResult.Outcome.SUCCESS, false, true);

        Test.startTest();
        List<SyncResult> results = WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'The sync itself should be unaffected.');
        Assert.areEqual(
            2,
            [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
            'Items must still be marked synced when their log rows cannot be written.'
        );
    }

    // ---------- limits and chunking ----------

    @IsTest
    static void stopsEarlyWhenTheCalloutTimeBudgetIsGone() {
        List<Work_Item__c> items = seed(3, 'In Progress');
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));
        WorkItemSyncService.calloutTimeBudgetMs = 0; // pretend the budget is already spent

        Test.startTest();
        List<SyncResult> results = WorkItemSyncService.syncStatuses(items);
        Test.stopTest();

        // Being killed mid-chunk loses the buffered logs, so stopping short is the safe failure.
        Assert.areEqual(0, results.size(), 'Nothing should be attempted with no budget left.');
        Assert.areEqual(
            3,
            [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Pending'],
            'Unattempted items keep their pending status for the next chunk.'
        );
    }

    @IsTest
    static void queueableProcessesOneChunkAndLeavesTheRest() {
        List<Work_Item__c> items = seed(200, 'In Progress');
        List<Id> ids = new List<Id>(new Map<Id, Work_Item__c>(items).keySet());
        // No HTTP: 200 items would be 400 callouts, and mocked callouts count against the limit.
        WorkItemAdapterFactory.injected = new FakeAdapter(SyncResult.Outcome.SUCCESS);

        Test.startTest();
        System.enqueueJob(new WorkItemSyncQueueable(ids));
        Test.stopTest();

        Assert.areEqual(
            WorkItemSyncService.DEFAULT_CHUNK_SIZE,
            [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'],
            'Exactly one chunk should have been processed.'
        );
        Assert.areEqual(
            200 - WorkItemSyncService.DEFAULT_CHUNK_SIZE,
            [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Pending'],
            'The remainder waits for the next link in the chain, which test context suppresses.'
        );
    }

    @IsTest
    static void bulkRunUsesConstantDml() {
        List<Work_Item__c> items = seed(200, 'In Progress');
        WorkItemAdapterFactory.injected = new FakeAdapter(SyncResult.Outcome.SUCCESS);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        WorkItemSyncService.syncStatuses(items);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // One update for the items, one insert for the logs, regardless of volume.
        Assert.areEqual(2, dmlUsed, 'DML must not scale with the number of records.');
        Assert.areEqual(200, [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'], 'All synced.');
    }

    @IsTest
    static void emptyAndNullInputAreNoOps() {
        Test.startTest();
        Assert.areEqual(0, WorkItemSyncService.syncStatuses(null).size(), 'Null input should be a no-op.');
        Assert.areEqual(0, WorkItemSyncService.syncStatuses(new List<Work_Item__c>()).size(), 'Empty likewise.');
        Assert.isNull(WorkItemSyncService.enqueue(new List<Id>()), 'Nothing to enqueue means no job.');
        Assert.isNull(WorkItemSyncService.enqueue(null), 'Null likewise.');
        Test.stopTest();
    }

    @IsTest
    static void enqueueReturnsAJobId() {
        List<Work_Item__c> items = seed(2, 'In Progress');
        WorkItemAdapterFactory.injected = new FakeAdapter(SyncResult.Outcome.SUCCESS);

        Test.startTest();
        Id jobId = WorkItemSyncService.enqueue(new List<Id>(new Map<Id, Work_Item__c>(items).keySet()));
        Test.stopTest();

        Assert.isNotNull(jobId, 'Callers need the job id to track the run.');
        Assert.areEqual(2, [SELECT COUNT() FROM Work_Item__c WHERE Sync_Status__c = 'Synced'], 'Job should have run.');
    }

    // ---------- factory ----------

    @IsTest
    static void factoryRoutesOnTheIdNamespace() {
        Test.startTest();
        Assert.isTrue(
            WorkItemAdapterFactory.forWorkItem(new Work_Item__c(External_Id__c = 'jira:10023')) instanceof JiraAdapter,
            'A jira-namespaced id should route to the Jira adapter.'
        );
        try {
            WorkItemAdapterFactory.forSystem('asana');
            Assert.fail('An unregistered system should be refused.');
        } catch (WorkItemAdapterFactory.UnsupportedSystemException e) {
            Assert.isTrue(e.getMessage().contains('asana'), 'Message should name the system.');
        }
        try {
            WorkItemAdapterFactory.forWorkItem(null);
            Assert.fail('A null work item should be refused.');
        } catch (WorkItemAdapterFactory.UnsupportedSystemException e) {
            Assert.isNotNull(e.getMessage(), 'Exception should explain itself.');
        }
        Test.stopTest();
    }
}
