/**
 * Proves TestDataFactory produces valid, insertable records at bulk volume, and that the two
 * properties later builds will depend on actually hold: External_Id__c is unique enough to
 * upsert against, and the factory's defaults do not trip the Work_Item__c validation rule.
 */
@IsTest
private class TestDataFactoryTest {
    private static final Integer BULK_SIZE = 200;

    @IsTest
    static void createProjectsInsertsAtBulkVolume() {
        Test.startTest();
        List<Project__c> projects = TestDataFactory.createProjects(BULK_SIZE, true);
        Test.stopTest();

        Assert.areEqual(BULK_SIZE, projects.size(), 'Factory should return one record per requested count.');
        Assert.areEqual(BULK_SIZE, [SELECT COUNT() FROM Project__c], 'Every project should have committed.');
        for (Project__c project : projects) {
            Assert.isNotNull(project.Id, 'doInsert = true should populate Ids on the returned list.');
        }
    }

    @IsTest
    static void createProjectsWithoutInsertLeavesRecordsUncommitted() {
        List<Project__c> projects = TestDataFactory.createProjects(5, false);

        Assert.areEqual(5, projects.size(), 'Factory should build records even when not inserting.');
        Assert.areEqual(0, [SELECT COUNT() FROM Project__c], 'doInsert = false must not commit anything.');
        for (Project__c project : projects) {
            Assert.isNull(project.Id, 'Uncommitted records should have no Id.');
        }
    }

    @IsTest
    static void createProjectsPopulatesFieldsWithinSchemaLimits() {
        TestDataFactory.createProjects(BULK_SIZE, true);

        for (Project__c project : [
            SELECT Name, Short_Name__c, Status__c, External_System__c, External_Project_Key__c
            FROM Project__c
        ]) {
            Assert.isNotNull(project.Name, 'Name is required on Project__c and must be populated.');
            Assert.isTrue(project.Short_Name__c.length() <= 20, 'Short_Name__c must fit Text(20).');
            Assert.areEqual('Planning', project.Status__c, 'Factory should seed the default status.');
            Assert.areEqual('Jira', project.External_System__c, 'Factory should seed a valid restricted picklist value.');
        }
    }

    @IsTest
    static void createWorkItemsInsertsAtBulkVolume() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];

        Test.startTest();
        List<Work_Item__c> workItems = TestDataFactory.createWorkItems(BULK_SIZE, project.Id, true);
        Test.stopTest();

        Assert.areEqual(BULK_SIZE, workItems.size(), 'Factory should return one record per requested count.');
        Assert.areEqual(BULK_SIZE, [SELECT COUNT() FROM Work_Item__c], 'Every work item should have committed.');
        Assert.areEqual(
            BULK_SIZE,
            [SELECT COUNT() FROM Work_Item__c WHERE Project__c = :project.Id],
            'Every work item should be linked to the supplied project.'
        );
    }

    @IsTest
    static void createWorkItemsProduceUniqueNamespacedExternalIds() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        List<Work_Item__c> workItems = TestDataFactory.createWorkItems(BULK_SIZE, project.Id, true);

        Set<String> externalIds = new Set<String>();
        for (Work_Item__c workItem : workItems) {
            Assert.isTrue(
                workItem.External_Id__c.startsWith('jira:'),
                'External ids must carry the system namespace, got: ' + workItem.External_Id__c
            );
            Assert.isTrue(workItem.External_Id__c.length() <= 100, 'External_Id__c must fit Text(100).');
            externalIds.add(workItem.External_Id__c);
        }
        Assert.areEqual(BULK_SIZE, externalIds.size(), 'Every work item needs a distinct External_Id__c.');
    }

    @IsTest
    static void externalIdSupportsUpsertWithoutDuplicating() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        List<Work_Item__c> existing = TestDataFactory.createWorkItems(BULK_SIZE, project.Id, true);

        // A second sync of the same remote issues: same external ids, new field values.
        List<Work_Item__c> incoming = new List<Work_Item__c>();
        for (Work_Item__c workItem : existing) {
            incoming.add(
                new Work_Item__c(
                    External_Id__c = workItem.External_Id__c,
                    Status__c = 'In Progress',
                    Sync_Status__c = 'Synced'
                )
            );
        }

        // This test is about external ids, not outbound sync. Without this, WorkItemTrigger sees
        // 200 genuine Status__c changes and enqueues a push, which then tries to call Jira with
        // no mock set. Suppressing is the honest statement of scope.
        SyncContext.suppressOutbound();

        Test.startTest();
        Database.upsert(incoming, Work_Item__c.External_Id__c, true);
        Test.stopTest();

        Assert.areEqual(
            BULK_SIZE,
            [SELECT COUNT() FROM Work_Item__c],
            'Upsert on External_Id__c should match the existing rows rather than insert duplicates.'
        );
        Assert.areEqual(
            BULK_SIZE,
            [SELECT COUNT() FROM Work_Item__c WHERE Status__c = 'In Progress' AND Sync_Status__c = 'Synced'],
            'Upsert should have carried the new field values onto every matched row.'
        );
    }

    @IsTest
    static void upsertOnUnknownExternalIdInsertsANewRow() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        TestDataFactory.createWorkItems(1, project.Id, true);

        Work_Item__c unseen = new Work_Item__c(
            External_Id__c = TestDataFactory.nextExternalId(),
            Project__c = project.Id
        );

        Test.startTest();
        Database.upsert(new List<Work_Item__c>{ unseen }, Work_Item__c.External_Id__c, true);
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Work_Item__c], 'An unmatched external id should insert.');
    }

    @IsTest
    static void factoryDefaultsSatisfyTheSyncStatusValidationRule() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        List<Work_Item__c> workItems = TestDataFactory.createWorkItems(1, project.Id, false);

        Assert.areEqual('Unspecified', workItems[0].Status__c, 'Factory should seed the unmapped status.');
        Assert.areEqual('Pending', workItems[0].Sync_Status__c, 'Factory should seed a sync status the rule allows.');

        insert workItems;
        Assert.isNotNull(workItems[0].Id, 'Factory defaults must be insertable as-is.');
    }

    @IsTest
    static void syncedIsRejectedWhileStatusIsUnspecified() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        Work_Item__c workItem = TestDataFactory.createWorkItems(1, project.Id, false)[0];
        workItem.Sync_Status__c = 'Synced'; // Status__c is still Unspecified.

        try {
            insert workItem;
            Assert.fail('Validation rule should block Synced while Status is Unspecified.');
        } catch (DmlException e) {
            Assert.isTrue(
                e.getMessage().contains('Sync Status cannot be Synced'),
                'Expected the validation rule message, got: ' + e.getMessage()
            );
        }
    }

    @IsTest
    static void createWorkItemsAcceptsANullProject() {
        List<Work_Item__c> workItems = TestDataFactory.createWorkItems(5, null, true);

        Assert.areEqual(5, workItems.size(), 'Orphan work items should still be built.');
        Assert.areEqual(
            5,
            [SELECT COUNT() FROM Work_Item__c WHERE Project__c = NULL],
            'A null projectId should leave the lookup empty rather than fail.'
        );
    }

    @IsTest
    static void storyPointsRetainOneDecimalPlace() {
        Project__c project = TestDataFactory.createProjects(1, true)[0];
        TestDataFactory.createWorkItems(BULK_SIZE, project.Id, true);

        Assert.isTrue(
            [SELECT COUNT() FROM Work_Item__c WHERE Story_Points__c = 0.5] > 0,
            'Number(4,1) should preserve half-point estimates rather than rounding them away.'
        );
    }
}