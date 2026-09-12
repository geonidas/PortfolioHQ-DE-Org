/**
 * Covers the wire contract with Jira: what goes out, and how each class of answer is classified.
 */
@IsTest
private class JiraAdapterTest {
    private static Work_Item__c workItem(String status, String syncStatus) {
        return new Work_Item__c(
            External_Id__c = 'jira:10023',
            External_System__c = 'Jira',
            Status__c = status,
            Sync_Status__c = syncStatus
        );
    }

    // ---------- what we send ----------

    @IsTest
    static void sendsTheTransitionsPathWithTheNamespaceStripped() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        // The stored id is jira:10023; Jira must receive 10023 or it answers 404.
        String expected = 'callout:Jira_Classic/rest/api/3/issue/10023/transitions';
        Assert.areEqual(expected, mock.firstCall().endpoint, 'Namespace must be stripped from the path.');
        Assert.isFalse(mock.firstCall().endpoint.contains('jira%3A'), 'The prefix must not survive URL encoding.');
    }

    @IsTest
    static void sendsGetThenPostWithTheChosenTransitionId() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(2, mock.callCount(), 'A status change is two calls: list, then apply.');
        Assert.areEqual('GET', mock.captured[0].method, 'First call lists transitions.');
        Assert.areEqual('POST', mock.captured[1].method, 'Second call applies one.');
        // Transition 11 is the one whose to.name is "In Progress"; its own name is "Start Progress".
        // Asserting on 11 is what proves we matched the destination status, not the button label.
        Assert.areEqual('{"transition":{"id":"11"}}', mock.captured[1].body, 'Wrong transition id posted.');
        Assert.areEqual(SyncResult.Outcome.SUCCESS, result.outcome, 'Should have succeeded.');
    }

    @IsTest
    static void setsJsonHeadersAndOmitsContentTypeWhenThereIsNoBody() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual('application/json', mock.captured[0].accept, 'GET should accept JSON.');
        Assert.isNull(mock.captured[0].contentType, 'A bodiless GET should not declare a content type.');
        Assert.areEqual('application/json', mock.captured[1].accept, 'POST should accept JSON.');
        Assert.areEqual('application/json', mock.captured[1].contentType, 'POST sends JSON.');
    }

    @IsTest
    static void matchesAJiraStatusNameThroughTheAliasTable() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.ALIAS_ONLY);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('Done', 'Pending'), 'Done');
        Test.stopTest();

        // Jira calls it "Resolved"; we call it "Done".
        Assert.areEqual(SyncResult.Outcome.SUCCESS, result.outcome, 'Alias should have matched: ' + result.message);
        Assert.areEqual('{"transition":{"id":"41"}}', mock.captured[1].body, 'Should have posted the alias transition.');
    }

    // ---------- how answers are classified ----------

    @IsTest
    static void unavailableTransitionIsABusinessOutcomeNotAFailure() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.NO_MATCHING_TRANSITION);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.NO_TRANSITION_AVAILABLE, result.outcome, 'Should be a handled outcome.');
        Assert.isTrue(result.isBusinessOutcome(), 'A workflow saying no is not a fault.');
        Assert.isFalse(result.isSuccess(), 'Nothing was transitioned.');
        Assert.areEqual(1, mock.callCount(), 'Must not POST when no transition matched.');
        // "Surface it clearly" means naming what was actually on offer.
        Assert.isTrue(result.message.contains('Done'), 'Message should list what was available: ' + result.message);
    }

    @IsTest
    static void terminalIssueReportsNoneAvailable() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.NO_TRANSITIONS_AT_ALL));

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('Done', 'Pending'), 'Done');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.NO_TRANSITION_AVAILABLE, result.outcome, 'Nowhere to go.');
        Assert.isTrue(result.message.contains('none'), 'Should say none were available: ' + result.message);
    }

    @IsTest
    static void unauthorizedIsDistinctFromOtherFailures() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED));

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.UNAUTHORIZED, result.outcome, '401 should classify as UNAUTHORIZED.');
        Assert.areEqual(401, result.statusCode, 'Status code should be carried through.');
        Assert.isFalse(result.isBusinessOutcome(), 'A bad token is a fault, not a business answer.');
    }

    @IsTest
    static void rateLimitIsDistinctFromAServerError() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.RATE_LIMITED));

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.RATE_LIMITED, result.outcome, '429 should be its own outcome.');
        Assert.areEqual(429, result.statusCode, 'Status code should be carried through.');
    }

    @IsTest
    static void serverErrorIsRemoteError() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.SERVER_ERROR));

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.REMOTE_ERROR, result.outcome, '500 should be REMOTE_ERROR.');
        Assert.areEqual(500, result.statusCode, 'Status code should be carried through.');
    }

    @IsTest
    static void failureOnTheSecondLegIsStillReported() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.POST_FAILS);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(2, mock.callCount(), 'The listing succeeded, so the POST was attempted.');
        Assert.areEqual(SyncResult.Outcome.REMOTE_ERROR, result.outcome, 'A failed POST must not read as success.');
    }

    @IsTest
    static void unparseableBodyIsARemoteErrorNotAnUnhandledException() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.MALFORMED_BODY));

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.REMOTE_ERROR, result.outcome, 'Garbage should be caught, not thrown.');
        Assert.isTrue(result.message.contains('parse'), 'Message should say what went wrong: ' + result.message);
    }

    // ---------- requests we refuse to make ----------

    @IsTest
    static void rejectsBadRequestsWithoutCallingJira() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK);
        Test.setMock(HttpCalloutMock.class, mock);
        JiraAdapter adapter = new JiraAdapter();

        Test.startTest();
        Map<String, SyncResult> results = new Map<String, SyncResult>{
            'null item' => adapter.updateStatus(null, 'Done'),
            'blank target' => adapter.updateStatus(workItem('To Do', 'Pending'), '   '),
            'unspecified target' => adapter.updateStatus(workItem('To Do', 'Pending'), 'Unspecified'),
            'unknown status' => adapter.updateStatus(workItem('To Do', 'Pending'), 'Marinating'),
            'wrong system' => adapter.updateStatus(
                new Work_Item__c(External_Id__c = 'asana:998877', Status__c = 'To Do', Sync_Status__c = 'Pending'),
                'Done'
            ),
            'unqualified id' => adapter.updateStatus(
                new Work_Item__c(External_Id__c = '10023', Status__c = 'To Do', Sync_Status__c = 'Pending'),
                'Done'
            )
        };
        Test.stopTest();

        for (String label : results.keySet()) {
            Assert.areEqual(
                SyncResult.Outcome.BAD_REQUEST,
                results.get(label).outcome,
                label + ' should be rejected as a bad request.'
            );
        }
        Assert.areEqual(0, mock.callCount(), 'A rejected request must not reach Jira.');
        Assert.areEqual(0, adapter.drainLogs().size(), 'No callout means no callout log.');
    }

    @IsTest
    static void skipsTheCalloutOnlyWhenTheRemoteIsBelievedToAgree() {
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SyncResult settled = new JiraAdapter().updateStatus(workItem('In Progress', 'Synced'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.ALREADY_IN_TARGET_STATUS, settled.outcome, 'Nothing to do.');
        Assert.isTrue(settled.isSuccess(), 'Already being there counts as success.');
        Assert.areEqual(0, mock.callCount(), 'No callout should be made.');
    }

    @IsTest
    static void doesNotSkipWhenTheLastSyncDidNotSucceed() {
        // Regression guard. The service passes item.Status__c as its own target, so a skip test
        // based on status alone is always true and nothing would ever sync. Sync_Status__c is
        // what makes the "already there" belief credible.
        JiraCalloutMock mock = new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SyncResult result = new JiraAdapter().updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        Assert.areEqual(SyncResult.Outcome.SUCCESS, result.outcome, 'A pending item must actually sync.');
        Assert.areEqual(2, mock.callCount(), 'Both callouts should have been made.');
    }

    // ---------- logging ----------

    @IsTest
    static void buffersOneLogPerCalloutAndClearsOnDrain() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));
        JiraAdapter adapter = new JiraAdapter();

        Test.startTest();
        adapter.updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        List<Integration_Log__c> logs = adapter.drainLogs();
        Assert.areEqual(2, logs.size(), 'One row per callout.');
        Assert.areEqual('GET', logs[0].HTTP_Method__c, 'First row is the listing.');
        Assert.areEqual('POST', logs[1].HTTP_Method__c, 'Second row is the transition.');
        Assert.areEqual(204, logs[1].Status_Code__c.intValue(), 'Jira answers 204 to a transition.');
        for (Integration_Log__c log : logs) {
            Assert.areEqual('Outbound', log.Direction__c, 'These are outbound calls.');
            Assert.isTrue(log.Is_Success__c, '2xx should be recorded as success.');
            Assert.isTrue(log.Duration_ms__c >= 0, 'Duration should be recorded.');
            Assert.isTrue(log.Endpoint__c.contains('/transitions'), 'Endpoint should be recorded.');
        }
        Assert.areEqual(0, adapter.drainLogs().size(), 'Draining should empty the buffer.');
    }

    @IsTest
    static void logsFailedCalloutsToo() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.UNAUTHORIZED));
        JiraAdapter adapter = new JiraAdapter();

        Test.startTest();
        adapter.updateStatus(workItem('In Progress', 'Pending'), 'In Progress');
        Test.stopTest();

        List<Integration_Log__c> logs = adapter.drainLogs();
        Assert.areEqual(1, logs.size(), 'The failed listing should still be logged.');
        Assert.areEqual(401, logs[0].Status_Code__c.intValue(), 'Real status code should be recorded.');
        Assert.isFalse(logs[0].Is_Success__c, '401 is not a success.');
        Assert.isTrue(logs[0].Response_Body__c.contains('authenticated'), 'Response body should be captured.');
    }

    // ---------- fetchAvailableTransitions ----------

    @IsTest
    static void fetchReturnsVendorNeutralOptions() {
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.TRANSITION_OK));

        Test.startTest();
        List<TransitionOption> options = new JiraAdapter().fetchAvailableTransitions('jira:10023');
        Test.stopTest();

        Assert.areEqual(3, options.size(), 'All three transitions should come back.');
        Map<String, String> idByStatus = new Map<String, String>();
        for (TransitionOption option : options) {
            idByStatus.put(option.targetStatus, option.id);
        }
        Assert.areEqual('11', idByStatus.get('In Progress'), 'Options carry the destination status, not the label.');
        Assert.areEqual('31', idByStatus.get('Done'), 'Options carry the destination status, not the label.');
    }

    @IsTest
    static void fetchThrowsOnTechnicalFailureSoEmptyMeansTerminal() {
        // An empty list has to mean "nowhere to go". If a 500 also returned empty, the caller
        // could not tell a terminal issue from a broken integration.
        Test.setMock(HttpCalloutMock.class, new JiraCalloutMock(JiraCalloutMock.Scenario.SERVER_ERROR));

        Test.startTest();
        try {
            new JiraAdapter().fetchAvailableTransitions('jira:10023');
            Assert.fail('A 500 should raise, not return empty.');
        } catch (AdapterException e) {
            Assert.isTrue(e.getMessage().contains('500'), 'Message should carry the status: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void fetchRejectsAnIdFromAnotherSystem() {
        Test.startTest();
        try {
            new JiraAdapter().fetchAvailableTransitions('asana:998877');
            Assert.fail('A non-Jira id should be refused.');
        } catch (AdapterException e) {
            Assert.isTrue(e.getMessage().contains('asana'), 'Message should name the offending id.');
        }
        Test.stopTest();
    }
}