/**
 * Asserts the guest user's reach stays minimal.
 *
 * The primary assertions read the permission set's own grants, because that is deterministic on
 * a freshly deployed org - a scratch org built from the project definition may have no site and
 * therefore no guest user at all. The runtime check runs opportunistically when one does exist.
 */
@IsTest
private class GuestAccessTest {
    /** Objects the guest must never reach, from deliverable 5. */
    private static final Set<String> FORBIDDEN = new Set<String>{
        'Work_Item__c',
        'Project__c',
        'Integration_Log__c',
        'Integration_Secret__mdt',
        'Account',
        'Contact',
        'Opportunity',
        'User',
        'Case'
    };

    private static List<ObjectPermissions> guestObjectGrants() {
        return [
            SELECT SobjectType, PermissionsRead, PermissionsCreate, PermissionsEdit, PermissionsDelete,
                PermissionsViewAllRecords, PermissionsModifyAllRecords
            FROM ObjectPermissions
            WHERE ParentId IN (SELECT Id FROM PermissionSet WHERE Name = 'Jira_Webhook_Guest')
        ];
    }

    @IsTest
    static void guestGrantsNoAccessToRestrictedObjects() {
        List<ObjectPermissions> grants = guestObjectGrants();
        Assert.isFalse(grants.isEmpty(), 'The guest permission set should exist and grant something.');

        for (ObjectPermissions grant : grants) {
            Assert.isFalse(
                FORBIDDEN.contains(grant.SobjectType),
                'Guest must have no access to ' + grant.SobjectType
            );
        }
    }

    @IsTest
    static void guestHoldsOnlyCreateAndReadOnWhatItNeeds() {
        Set<String> allowed = new Set<String>{ 'Webhook_Event__c', 'Webhook_Event_Received__e' };

        for (ObjectPermissions grant : guestObjectGrants()) {
            Assert.isTrue(allowed.contains(grant.SobjectType), 'Unexpected object granted: ' + grant.SobjectType);
            Assert.isTrue(grant.PermissionsCreate, 'Create is the point: ' + grant.SobjectType);
            // Read is a platform prerequisite for Create and cannot be withheld.
            Assert.isFalse(grant.PermissionsEdit, 'Guest must never edit ' + grant.SobjectType);
            Assert.isFalse(grant.PermissionsDelete, 'Guest must never delete ' + grant.SobjectType);
            Assert.isFalse(grant.PermissionsViewAllRecords, 'Guest must never view all ' + grant.SobjectType);
            Assert.isFalse(grant.PermissionsModifyAllRecords, 'Guest must never modify all ' + grant.SobjectType);
        }
    }

    @IsTest
    static void guestRunsOnlyTheEndpointClass() {
        List<SetupEntityAccess> classAccess = [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId IN (SELECT Id FROM PermissionSet WHERE Name = 'Jira_Webhook_Guest')
                AND SetupEntityType = 'ApexClass'
        ];
        Assert.areEqual(1, classAccess.size(), 'Exactly one class: the REST endpoint.');

        Set<Id> allowed = new Set<Id>();
        for (SetupEntityAccess access : classAccess) {
            allowed.add(access.SetupEntityId);
        }
        List<ApexClass> named = [SELECT Name FROM ApexClass WHERE Id IN :allowed];
        Assert.areEqual('JiraWebhookResource', named[0].Name, 'And it is the endpoint, not something else.');
    }

    @IsTest
    static void guestFieldAccessIsConfinedToTheDeliveryObject() {
        List<FieldPermissions> fields = [
            SELECT SobjectType, Field, PermissionsEdit
            FROM FieldPermissions
            WHERE ParentId IN (SELECT Id FROM PermissionSet WHERE Name = 'Jira_Webhook_Guest')
        ];
        Assert.isFalse(fields.isEmpty(), 'The endpoint needs field access to write its row.');
        for (FieldPermissions field : fields) {
            Assert.areEqual('Webhook_Event__c', field.SobjectType, 'No field access outside the delivery object: ' + field.Field);
        }
    }

    @IsTest
    static void guestCannotReadRestrictedObjectsAtRuntime() {
        List<User> guests = [SELECT Id FROM User WHERE UserType = 'Guest' AND IsActive = TRUE LIMIT 1];
        if (guests.isEmpty()) {
            // A scratch org built from the project definition may have no site yet. The
            // permission-set assertions above still hold; there is simply nobody to run as.
            return;
        }

        Boolean workItemRefused = false;
        Boolean projectRefused = false;
        System.runAs(guests[0]) {
            try {
                Integer ignored = [SELECT COUNT() FROM Work_Item__c WITH USER_MODE];
            } catch (Exception e) {
                workItemRefused = true;
            }
            try {
                Integer ignored = [SELECT COUNT() FROM Project__c WITH USER_MODE];
            } catch (Exception e) {
                projectRefused = true;
            }
        }
        Assert.isTrue(workItemRefused, 'Guest must not be able to read Work_Item__c.');
        Assert.isTrue(projectRefused, 'Guest must not be able to read Project__c.');
    }

    @IsTest
    static void theSecretIsNotReachableThroughAnyGuestGrant() {
        // Protected custom metadata is readable by Apex in this org but is not exposed to a user,
        // and no guest grant references it either.
        for (ObjectPermissions grant : guestObjectGrants()) {
            Assert.areNotEqual('Integration_Secret__mdt', grant.SobjectType, 'Guest must not reach the secret type.');
        }
        Assert.areEqual(
            0,
            [
                SELECT COUNT()
                FROM SetupEntityAccess
                WHERE ParentId IN (SELECT Id FROM PermissionSet WHERE Name = 'Jira_Webhook_Guest')
                    AND SetupEntityType = 'CustomEntityDefinition'
            ],
            'No custom entity access should be granted to the guest set.'
        );
    }
}
