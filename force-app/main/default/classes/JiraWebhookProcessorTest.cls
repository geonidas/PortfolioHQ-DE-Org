/**
 * Processor behaviour: ordering, idempotency, loop prevention and bulk.
 *
 * Events are inserted BEFORE Test.startTest so their platform events are delivered at stopTest,
 * by which point process() has already run and moved the rows off Pending - so the subscriber
 * finds nothing and cannot double-process. Tests that want the real event path say so.
 */
@IsTest
private class JiraWebhookProcessorTest {
    private static Work_Item__c seedItem(String externalId, String status, Datetime remoteUpdated) {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        Work_Item__c item = TestDataFactory.createWorkItems(1, project.Id, false)[0];
        item.External_Id__c = externalId;
        item.Status__c = status;
        item.Sync_Status__c = 'Pending';
        item.Remote_Last_Modified__c = remoteUpdated;
        insert item;
        return item;
    }

    private static List<Webhook_Event__c> deliver(List<String> payloads) {
        List<Webhook_Event__c> events = new List<Webhook_Event__c>();
        for (String payload : payloads) {
            events.add(JiraWebhookPayloadFactory.delivery(payload));
        }
        insert events;
        return [SELECT Id, Raw_Payload__c, Processing_Status__c, Signature_Valid__c FROM Webhook_Event__c];
    }

    // ---------- applying changes ----------

    @IsTest
    static void appliesANewerChange() {
        Datetime was = System.now().addHours(-1);
        Work_Item__c item = seedItem('jira:10039', 'To Do', was);
        List<Webhook_Event__c> events = deliver(
            new List<String>{ JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'In Progress', was.addMinutes(30)) }
        );

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        Work_Item__c updated = [SELECT Status__c, Sync_Status__c, Last_Synced__c, Remote_Last_Modified__c FROM Work_Item__c WHERE Id = :item.Id];
        Assert.areEqual('In Progress', updated.Status__c, 'Newer change should be applied.');
        Assert.areEqual('Synced', updated.Sync_Status__c, 'Applying a remote change means we now agree.');
        Assert.isNotNull(updated.Last_Synced__c, 'Last_Synced__c should be stamped.');
        Assert.areEqual('Processed', [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1].Processing_Status__c, 'Terminal.');
    }

    @IsTest
    static void translatesJiraVocabularyThroughTheSharedMapping() {
        Datetime was = System.now().addHours(-1);
        Work_Item__c item = seedItem('jira:10039', 'To Do', was);
        // Jira says 'Resolved'; our vocabulary calls that 'Done'. Same table the outbound path uses.
        List<Webhook_Event__c> events = deliver(
            new List<String>{ JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'Resolved', was.addMinutes(30)) }
        );

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        Assert.areEqual('Done', [SELECT Status__c FROM Work_Item__c WHERE Id = :item.Id].Status__c, 'Alias should normalize.');
    }

    @IsTest
    static void anUnmappedStatusLandsOnUnspecifiedWithoutBreakingTheValidationRule() {
        Datetime was = System.now().addHours(-1);
        Work_Item__c item = seedItem('jira:10039', 'To Do', was);
        List<Webhook_Event__c> events = deliver(
            new List<String>{ JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'Blocked', was.addMinutes(30)) }
        );

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        Work_Item__c updated = [SELECT Status__c, Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id];
        Assert.areEqual('Unspecified', updated.Status__c, 'An unmapped Jira status lands on the catch-all.');
        // Synced alongside Unspecified violates Sync_Status_Requires_Known_Status from build 01.
        Assert.areEqual('Pending', updated.Sync_Status__c, 'Must not claim Synced with an unmapped status.');
        Webhook_Event__c event = [SELECT Processing_Status__c, Error_Message__c FROM Webhook_Event__c LIMIT 1];
        Assert.areEqual('Processed', event.Processing_Status__c, 'It was applied, so it is processed.');
        Assert.isTrue(event.Error_Message__c.contains('Blocked'), 'The unmapped status should be named: ' + event.Error_Message__c);
    }

    @IsTest
    static void anUnknownExternalIdCreatesTheWorkItem() {
        // An issue created in Jira that Salesforce has never seen. Normal, not an error.
        List<Webhook_Event__c> events = deliver(
            new List<String>{ JiraWebhookPayloadFactory.issueUpdated('10500', 'DOPP-99', 'In Progress', System.now()) }
        );

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        List<Work_Item__c> created = [SELECT External_Id__c, External_Key__c, Status__c, External_System__c FROM Work_Item__c];
        Assert.areEqual(1, created.size(), 'An unseen issue should be created.');
        Assert.areEqual('jira:10500', created[0].External_Id__c, 'Stored namespaced, matching the upsert key.');
        Assert.areEqual('DOPP-99', created[0].External_Key__c, 'Key recorded so the record is identifiable.');
        Assert.areEqual('In Progress', created[0].Status__c, 'Status applied.');
        Assert.areEqual('Processed', [SELECT Processing_Status__c FROM Webhook_Event__c LIMIT 1].Processing_Status__c, 'Terminal.');
    }

    // ---------- ordering and idempotency ----------

    @IsTest
    static void theSameDeliveryTwiceProducesOneWorkItem() {
        Datetime updated = System.now();
        String payload = JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'In Progress', updated);
        List<Webhook_Event__c> events = deliver(new List<String>{ payload, payload });

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Work_Item__c], 'A duplicate delivery must not duplicate the record.');
        Assert.areEqual(1, [SELECT COUNT() FROM Webhook_Event__c WHERE Processing_Status__c = 'Processed'], 'One applied.');
        Assert.areEqual(1, [SELECT COUNT() FROM Webhook_Event__c WHERE Processing_Status__c = 'Ignored'], 'One ignored.');
    }

    @IsTest
    static void anOlderDeliveryArrivingLateIsIgnored() {
        Datetime now = System.now();
        Work_Item__c item = seedItem('jira:10039', 'Done', now);
        // Jira does not guarantee ordering. This one describes a state we have already moved past.
        List<Webhook_Event__c> events = deliver(
            new List<String>{ JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'To Do', now.addMinutes(-30)) }
        );

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        Assert.areEqual('Done', [SELECT Status__c FROM Work_Item__c WHERE Id = :item.Id].Status__c, 'Stale data must not win.');
        Webhook_Event__c event = [SELECT Processing_Status__c, Error_Message__c FROM Webhook_Event__c LIMIT 1];
        Assert.areEqual('Ignored', event.Processing_Status__c, 'Ignored is a success, not a failure.');
        Assert.isTrue(event.Error_Message__c.contains('not newer'), 'Reason recorded: ' + event.Error_Message__c);
    }

    @IsTest
    static void onlyTheNewestDeliveryInABatchIsApplied() {
        Datetime base = System.now().addHours(-1);
        seedItem('jira:10039', 'To Do', base);

        Test.startTest();
        JiraWebhookProcessor.process(
            deliver(
                new List<String>{
                    JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'In Progress', base.addMinutes(10)),
                    JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'Done', base.addMinutes(30)),
                    JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'In Review', base.addMinutes(20))
                }
            )
        );
        Test.stopTest();

        // Arrival order must not decide the outcome; the timestamps must.
        Assert.areEqual('Done', [SELECT Status__c FROM Work_Item__c LIMIT 1].Status__c, 'Newest by timestamp wins.');
        Assert.areEqual(2, [SELECT COUNT() FROM Webhook_Event__c WHERE Processing_Status__c = 'Ignored'], 'Others superseded.');
    }

    // ---------- loop prevention ----------

    @IsTest
    static void inboundProcessingEnqueuesNoOutboundCall() {
        Datetime was = System.now().addHours(-1);
        seedItem('jira:10039', 'To Do', was);
        List<Webhook_Event__c> events = deliver(
            new List<String>{ JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'In Progress', was.addMinutes(30)) }
        );

        Test.startTest();
        Integer before = Limits.getQueueableJobs();
        JiraWebhookProcessor.process(events);
        Integer after = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(before, after, 'Applying a webhook must not push straight back to Jira.');
        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c], 'And no callout should have been logged.');
    }

    @IsTest
    static void anOrdinaryStatusChangeDoesEnqueueAnOutboundCall() {
        // Negative control. Without this, the test above would pass even if suppression were
        // broken and the trigger simply never fired.
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));
        Work_Item__c item = seedItem('jira:10039', 'To Do', System.now());

        Test.startTest();
        Integer before = Limits.getQueueableJobs();
        update new Work_Item__c(Id = item.Id, Status__c = 'In Progress');
        Integer after = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(before + 1, after, 'A genuine Salesforce-side status change should push outbound.');
    }

    @IsTest
    static void aPreviouslySyncedRecordStillPushesWhenItsStatusChanges() {
        // Regression guard. The adapter skips its callout for anything marked Synced, so without
        // before-update staging a record synced once would never sync again - and would report
        // success while Jira never heard about it. Asserting on the enqueue alone missed this:
        // the job ran, made no callout, and stamped the record Synced anyway.
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK);
        Test.setMock(HttpCalloutMock.class, mock);

        Project__c project = TestDataFactory.createProjects(1, true)[0];
        Work_Item__c item = TestDataFactory.createWorkItems(1, project.Id, false)[0];
        item.External_Id__c = 'jira:10039';
        item.Status__c = 'To Do';
        item.Sync_Status__c = 'Synced'; // the state that used to go silent
        insert item;

        Test.startTest();
        update new Work_Item__c(Id = item.Id, Status__c = 'In Progress');
        Test.stopTest();

        Assert.areEqual(2, mock.callCount(), 'A real status change must reach Jira: list, then transition.');
        Assert.areEqual(
            2,
            [SELECT COUNT() FROM Integration_Log__c],
            'And the callouts must be logged, which is how this failure was visible at all.'
        );
        Assert.areEqual('Synced', [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id].Sync_Status__c,
            'Only after a real push may it claim to be synced.');
    }

    @IsTest
    static void stagingLeavesAnExplicitSyncStatusAlone() {
        // A caller that sets Sync_Status__c in the same update means it; staging must not override.
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));
        Work_Item__c item = seedItem('jira:10039', 'To Do', System.now());

        Test.startTest();
        update new Work_Item__c(Id = item.Id, Status__c = 'In Progress', Sync_Status__c = 'Failed');
        Test.stopTest();

        Assert.areNotEqual('Pending', [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id].Sync_Status__c,
            'An explicitly supplied Sync_Status__c beats the inferred one.');
    }

    @IsTest
    static void inboundKeepsItsOwnSyncStatusThroughStaging() {
        // Inbound sets Synced deliberately. Staging runs on the same DML and must stand down.
        Datetime was = System.now().addHours(-1);
        Work_Item__c item = seedItem('jira:10039', 'To Do', was);
        List<Webhook_Event__c> events = deliver(
            new List<String>{ JiraWebhookPayloadFactory.issueUpdated('10039', 'DOPP-15', 'In Progress', was.addMinutes(30)) }
        );

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        Assert.areEqual('Synced', [SELECT Sync_Status__c FROM Work_Item__c WHERE Id = :item.Id].Sync_Status__c,
            'Suppression must stop staging from downgrading an inbound-applied change to Pending.');
        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c], 'And still no outbound traffic.');
    }

    @IsTest
    static void awriteThatChangesNoStatusEnqueuesNothing() {
        // Build 02 writes Sync_Status__c and Last_Synced__c back after every sync. Without the
        // delta check those writes would re-trigger the sync that produced them.
        Work_Item__c item = seedItem('jira:10039', 'To Do', System.now());

        Test.startTest();
        Integer before = Limits.getQueueableJobs();
        update new Work_Item__c(Id = item.Id, Sync_Status__c = 'Failed');
        Integer after = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(before, after, 'Only a Status__c change is a reason to sync.');
    }

    @IsTest
    static void suppressionUnwindsByDepthNotByFlag() {
        SyncContext.reset();
        Assert.isFalse(SyncContext.isOutboundSuppressed(), 'Clean start.');
        SyncContext.suppressOutbound();
        SyncContext.suppressOutbound();
        SyncContext.resumeOutbound();
        Assert.isTrue(SyncContext.isOutboundSuppressed(), 'An inner resume must not lift an outer block.');
        SyncContext.resumeOutbound();
        Assert.isFalse(SyncContext.isOutboundSuppressed(), 'Balanced calls clear it.');
        SyncContext.resumeOutbound();
        Assert.isFalse(SyncContext.isOutboundSuppressed(), 'Extra resumes must not go negative.');
    }

    // ---------- bad input ----------

    @IsTest
    static void malformedJsonFailsTheEventAndNothingElse() {
        List<Webhook_Event__c> events = deliver(new List<String>{ 'this is not json at all' });

        Test.startTest();
        JiraWebhookProcessor.process(events); // must not throw
        Test.stopTest();

        Webhook_Event__c event = [SELECT Processing_Status__c, Error_Message__c FROM Webhook_Event__c LIMIT 1];
        Assert.areEqual('Failed', event.Processing_Status__c, 'Unparseable input is a failed event.');
        Assert.isTrue(event.Error_Message__c.contains('Malformed JSON'), 'Reason recorded: ' + event.Error_Message__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Work_Item__c], 'Nothing should have been written.');
    }

    @IsTest
    static void structurallyValidJsonMissingWhatWeNeedFailsCleanly() {
        List<Webhook_Event__c> events = deliver(
            new List<String>{
                '{"webhookEvent":"jira:issue_updated"}',
                '{"webhookEvent":"jira:issue_updated","issue":{"key":"DOPP-1","fields":{}}}',
                '{"webhookEvent":"jira:issue_updated","issue":{"id":"10039","fields":{"status":{"name":"Done"}}}}'
            }
        );

        Test.startTest();
        JiraWebhookProcessor.process(events);
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM Webhook_Event__c WHERE Processing_Status__c = 'Failed'],
            'No issue, no id, and no timestamp are each a clean failure.');
        Assert.areEqual(0, [SELECT COUNT() FROM Work_Item__c], 'Nothing written.');
    }

    @IsTest
    static void emptyAndNullInputAreNoOps() {
        Test.startTest();
        JiraWebhookProcessor.process(null);
        JiraWebhookProcessor.process(new List<Webhook_Event__c>());
        JiraWebhookProcessor.handle(new List<Webhook_Event_Received__e>());
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM Work_Item__c], 'Nothing to do, nothing done.');
    }

    @IsTest
    static void parsesJirasFourDigitOffsetTimestamps() {
        Datetime expected = Datetime.newInstanceGmt(2026, 9, 12, 19, 13, 41);
        Assert.areEqual(expected, JiraWebhookProcessor.parseIso('2026-09-12T19:13:41.000+0000'), 'Jira wire format.');
        Assert.areEqual(expected, JiraWebhookProcessor.parseIso('2026-09-12T19:13:41.000+00:00'), 'RFC-3339 offset.');
        Assert.isNull(JiraWebhookProcessor.parseIso('not a date'), 'Garbage yields null, not an exception.');
        Assert.isNull(JiraWebhookProcessor.parseIso(null), 'Null yields null.');
    }

    // ---------- bulk ----------

    @IsTest
    static void handlesTwoHundredDeliveries() {
        Datetime base = System.now();
        List<String> payloads = new List<String>();
        for (Integer i = 0; i < 200; i++) {
            payloads.add(JiraWebhookPayloadFactory.issueUpdated(String.valueOf(20000 + i), 'DOPP-' + i, 'In Progress', base));
        }
        List<Webhook_Event__c> events = deliver(payloads);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        JiraWebhookProcessor.process(events);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Work_Item__c], '200 distinct issues, 200 records.');
        Assert.areEqual(200, [SELECT COUNT() FROM Webhook_Event__c WHERE Processing_Status__c = 'Processed'], 'All processed.');
        // One upsert for the work items, one update for the events, whatever the volume.
        Assert.areEqual(2, dmlUsed, 'DML must not scale with the number of events.');
        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c], 'And no outbound traffic from any of it.');
    }
}
