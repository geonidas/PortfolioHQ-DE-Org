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
      SELECT
        SobjectType,
        PermissionsRead,
        PermissionsCreate,
        PermissionsEdit,
        PermissionsDelete,
        PermissionsViewAllRecords,
        PermissionsModifyAllRecords
      FROM ObjectPermissions
      WHERE
        ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Jira_Webhook_Guest'
        )
    ];
  }

  /**
   * Fields the board guest must never hold, whatever else it is granted.
   *
   * Source_Type__c carries the type string exactly as a vendor sent it - on the Asana board,
   * whatever somebody typed into a custom field. Type__c is restricted precisely so that free
   * text cannot reach a public card, and this is the field that would undo it.
   */
  @IsTest
  static void theBoardGuestHoldsNoPrivateWorkItemFields() {
    Set<String> forbiddenFields = new Set<String>{
      'Work_Item__c.Source_Type__c',
      'Work_Item__c.Description__c',
      'Work_Item__c.Assignee__c',
      'Work_Item__c.External_URL__c'
    };

    List<FieldPermissions> granted = [
      SELECT Field, Parent.Name
      FROM FieldPermissions
      WHERE
        Field IN :forbiddenFields
        AND ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name IN ('Portfolio_HQ_Guest', 'Jira_Webhook_Guest')
        )
    ];
    Assert.areEqual(
      0,
      granted.size(),
      'A guest permission set granted a field that must never reach an anonymous visitor: ' +
      granted
    );
  }

  @IsTest
  static void guestGrantsNoAccessToRestrictedObjects() {
    List<ObjectPermissions> grants = guestObjectGrants();
    Assert.isFalse(
      grants.isEmpty(),
      'The guest permission set should exist and grant something.'
    );

    for (ObjectPermissions grant : grants) {
      Assert.isFalse(
        FORBIDDEN.contains(grant.SobjectType),
        'Guest must have no access to ' + grant.SobjectType
      );
    }
  }

  @IsTest
  static void guestHoldsOnlyCreateAndReadOnWhatItNeeds() {
    // Webhook_Secret__c joined this set in build 07 step 4, deliberately and not quietly -
    // this assertion failed first, which is what it is for. The endpoint stages a secret there
    // during the registration handshake. Create only, and the guest can never read the row
    // back in any mode, which is why verification reads Custom Metadata instead.
    Set<String> allowed = new Set<String>{
      'Webhook_Event__c',
      'Webhook_Event_Received__e',
      'Webhook_Secret__c'
    };

    for (ObjectPermissions grant : guestObjectGrants()) {
      Assert.isTrue(
        allowed.contains(grant.SobjectType),
        'Unexpected object granted: ' + grant.SobjectType
      );
      Assert.isTrue(
        grant.PermissionsCreate,
        'Create is the point: ' + grant.SobjectType
      );
      // Read is a platform prerequisite for Create and cannot be withheld.
      Assert.isFalse(
        grant.PermissionsEdit,
        'Guest must never edit ' + grant.SobjectType
      );
      Assert.isFalse(
        grant.PermissionsDelete,
        'Guest must never delete ' + grant.SobjectType
      );
      Assert.isFalse(
        grant.PermissionsViewAllRecords,
        'Guest must never view all ' + grant.SobjectType
      );
      Assert.isFalse(
        grant.PermissionsModifyAllRecords,
        'Guest must never modify all ' + grant.SobjectType
      );
    }
  }

  @IsTest
  static void guestRunsOnlyTheEndpointClasses() {
    List<SetupEntityAccess> classAccess = [
      SELECT SetupEntityId
      FROM SetupEntityAccess
      WHERE
        ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Jira_Webhook_Guest'
        )
        AND SetupEntityType = 'ApexClass'
    ];
    // One per vendor, and nothing else. Apex class access is granted per CLASS, not per method,
    // so every name on this list is every method a guest can invoke - which is why the set is
    // asserted exactly rather than checked for absences. AsanaWebhookResource joined it in
    // build 07 step 5, deliberately: this assertion failed first.
    Set<Id> allowed = new Set<Id>();
    for (SetupEntityAccess access : classAccess) {
      allowed.add(access.SetupEntityId);
    }
    Set<String> names = new Set<String>();
    for (ApexClass named : [SELECT Name FROM ApexClass WHERE Id IN :allowed]) {
      names.add(named.Name);
    }
    Assert.areEqual(
      new Set<String>{ 'AsanaWebhookResource', 'JiraWebhookResource' },
      names,
      'The endpoints, and nothing else. A board controller or a service here would expose ' +
      'every method on it to an anonymous visitor.'
    );
  }

  @IsTest
  static void guestFieldAccessIsConfinedToWhatItWrites() {
    List<FieldPermissions> fields = [
      SELECT SobjectType, Field, PermissionsEdit
      FROM FieldPermissions
      WHERE
        ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Jira_Webhook_Guest'
        )
    ];
    Assert.isFalse(
      fields.isEmpty(),
      'The endpoint needs field access to write its rows.'
    );
    // The two objects the endpoint writes and nothing else. Webhook_Secret__c is here because
    // the handshake stages a secret on it; the guest still cannot read either object's rows
    // back, which record access enforces regardless of what is granted here.
    Set<String> writable = new Set<String>{
      'Webhook_Event__c',
      'Webhook_Secret__c'
    };
    for (FieldPermissions field : fields) {
      Assert.isTrue(
        writable.contains(field.SobjectType),
        'No field access outside what the endpoint writes: ' + field.Field
      );
    }
  }

  @IsTest
  static void guestCannotReadRestrictedObjectsAtRuntime() {
    List<User> guests = [
      SELECT Id
      FROM User
      WHERE UserType = 'Guest' AND IsActive = TRUE
      LIMIT 1
    ];
    if (guests.isEmpty()) {
      // A scratch org built from the project definition may have no site yet. The
      // permission-set assertions above still hold; there is simply nobody to run as.
      return;
    }

    // Build 05 deliberately gave the guest read on Work_Item__c and Project__c through
    // Portfolio_HQ_Guest, so refusing those outright is no longer the correct expectation.
    // What must still hold is that the integration objects stay out of reach entirely.
    Boolean logRefused = false;
    Boolean secretRefused = false;
    System.runAs(guests[0]) {
      try {
        Integer ignored = [
          SELECT COUNT()
          FROM Integration_Log__c
          WITH USER_MODE
        ];
      } catch (Exception e) {
        logRefused = true;
      }
      try {
        Integer ignored = [
          SELECT COUNT()
          FROM Integration_Secret__mdt
          WITH USER_MODE
        ];
      } catch (Exception e) {
        secretRefused = true;
      }
    }
    Assert.isTrue(
      logRefused,
      'Guest must not be able to read Integration_Log__c.'
    );
    Assert.isTrue(
      secretRefused,
      'Guest must not be able to read Integration_Secret__mdt.'
    );
  }

  @IsTest
  static void guestReadsOnlyPublicWorkItems() {
    // The replacement for the assertion above. Object level read is now granted on purpose;
    // the guarantee moved down to the record level, where the sharing rules enforce it.
    List<User> guests = [
      SELECT Id
      FROM User
      WHERE UserType = 'Guest' AND IsActive = TRUE
      LIMIT 1
    ];
    if (guests.isEmpty()) {
      return;
    }

    Project__c project = TestDataFactory.createProjects(1, false)[0];
    project.Is_Public__c = true;
    insert project;
    List<Work_Item__c> items = TestDataFactory.createWorkItems(
      2,
      project.Id,
      false
    );
    items[0].Is_Public__c = true;
    items[1].Is_Public__c = false;
    insert items;

    Set<Id> visible = new Set<Id>();
    System.runAs(guests[0]) {
      for (Work_Item__c item : [SELECT Id FROM Work_Item__c WITH USER_MODE]) {
        visible.add(item.Id);
      }
    }
    // Sharing rules are asynchronous for records created inside a test, so this asserts the
    // direction that matters and can never be a false pass: the private record is absent.
    Assert.isFalse(
      visible.contains(items[1].Id),
      'A non-public work item must never be visible to a guest.'
    );
  }

  @IsTest
  static void theSecretIsNotReachableThroughAnyGuestGrant() {
    // Protected custom metadata is readable by Apex in this org but is not exposed to a user,
    // and no guest grant references it either.
    for (ObjectPermissions grant : guestObjectGrants()) {
      Assert.areNotEqual(
        'Integration_Secret__mdt',
        grant.SobjectType,
        'Guest must not reach the secret type.'
      );
    }
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM SetupEntityAccess
        WHERE
          ParentId IN (
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'Jira_Webhook_Guest'
          )
          AND SetupEntityType = 'CustomEntityDefinition'
      ],
      'No custom entity access should be granted to the guest set.'
    );
  }
}
