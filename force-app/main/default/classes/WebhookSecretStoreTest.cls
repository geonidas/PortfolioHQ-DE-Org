/**
 * The secret store, and the measurements that shaped it.
 *
 * Three kinds of assertion. Behavioural ones exercise staging and the lookup. Structural ones
 * read the org's own grant metadata and the deployed Apex, because what protects a secret on the
 * Apex path is not a permission - the guest cannot write Apex but it can invoke it, and Apex runs
 * in system mode - but the fact that no reachable method returns one. And one platform assertion,
 * which pins the behaviour the whole design rests on: a site guest cannot read a custom object row
 * back, even one it wrote itself. That is not configuration, and it is not something to rediscover
 * the next time somebody is tempted to keep a secret in a field.
 */
@IsTest
private class WebhookSecretStoreTest {
  private static final String SYSTEM_ASANA = ExternalSystem.ASANA;

  /** A throwaway secret, per run. A literal here would be a secret value in source control. */
  private static String randomSecret() {
    return EncodingUtil.convertToHex(Crypto.generateAesKey(256));
  }

  private static String resourceId() {
    return '12' + Math.abs(Crypto.getRandomLong());
  }

  private static User siteGuest() {
    List<User> guests = [
      SELECT Id, Name
      FROM User
      WHERE UserType = 'Guest' AND IsActive = TRUE
      ORDER BY CreatedDate ASC
      LIMIT 1
    ];
    return guests.isEmpty() ? null : guests[0];
  }

  // ---------- staging, which is the only write ----------

  @IsTest
  static void aHandshakeStagesTheSecretItWasGiven() {
    String gid = resourceId();
    String secret = randomSecret();

    Test.startTest();
    Boolean staged = WebhookSecretStore.stage(gid, SYSTEM_ASANA, secret);
    Test.stopTest();

    Assert.isTrue(staged, 'The handshake had something to record.');
    Webhook_Secret__c row = [
      SELECT Resource_Id__c, Source_System__c, Secret__c, Active__c
      FROM Webhook_Secret__c
      WHERE Resource_Id__c = :gid
    ];
    Assert.areEqual(secret, row.Secret__c, 'Recorded whole, not cut.');
    Assert.areEqual(SYSTEM_ASANA, row.Source_System__c);
    Assert.isTrue(row.Active__c, 'Staged rows start active.');
  }

  @IsTest
  static void aSecondRegistrationForTheSameResourceIsRefused() {
    // The endpoint is unauthenticated. An upsert here would let anyone who knows a resource gid
    // replace the real secret with one of their own and then sign whatever they liked, so the
    // unique key is a security control rather than tidiness. It is also the only option: the
    // guest user licence forbids Edit on a custom object outright.
    String gid = resourceId();
    String genuine = randomSecret();

    Test.startTest();
    Boolean first = WebhookSecretStore.stage(gid, SYSTEM_ASANA, genuine);
    Boolean second = WebhookSecretStore.stage(gid, SYSTEM_ASANA, 'attacker');
    Test.stopTest();

    Assert.isTrue(first, 'The genuine registration lands.');
    Assert.isFalse(
      second,
      'And a second one for the same resource is refused, so the caller answers non-2xx and ' +
      'registration does not complete.'
    );
    Assert.areEqual(
      genuine,
      [
        SELECT Secret__c
        FROM Webhook_Secret__c
        WHERE Resource_Id__c = :gid
      ]
      .Secret__c,
      'The secret already recorded is untouched.'
    );
  }

  @IsTest
  static void aSecretTooLongIsRefusedRatherThanCut() {
    String gid = resourceId();
    Integer cap = Webhook_Secret__c.Secret__c.getDescribe().getLength();
    Assert.areEqual(255, cap, 'Text tops out at 255.');

    Test.startTest();
    Boolean staged = WebhookSecretStore.stage(
      gid,
      SYSTEM_ASANA,
      'a'.repeat(cap + 1)
    );
    Test.stopTest();

    Assert.isFalse(
      staged,
      'Truncating would record a key that verifies nothing, and the caller would answer the ' +
      'handshake 200 - registering a webhook whose every delivery then fails.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Webhook_Secret__c WHERE Resource_Id__c = :gid],
      'And nothing was written.'
    );
  }

  @IsTest
  static void blankInputIsRefusedWithoutThrowing() {
    Test.startTest();
    Boolean noId = WebhookSecretStore.stage('', SYSTEM_ASANA, randomSecret());
    Boolean noSecret = WebhookSecretStore.stage(resourceId(), SYSTEM_ASANA, '');
    Boolean allNull = WebhookSecretStore.stage(null, null, null);
    Test.stopTest();

    Assert.isFalse(noId, 'A handshake with nothing to key on is a rejection.');
    Assert.isFalse(noSecret, 'And so is one carrying no secret.');
    Assert.isFalse(allNull, 'Nulls reject, they do not crash.');
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Webhook_Secret__c],
      'Nothing was written by any of them.'
    );
  }

  // ---------- the lookup, which reads Custom Metadata and not the staged row ----------

  @IsTest
  static void averifiedSecretIsReadFromCustomMetadata() {
    String gid = resourceId();
    String secret = randomSecret();
    // Custom metadata records cannot be created by DML, so a promoted secret can only be
    // simulated. The real read path is IntegrationSecretService, exercised by its own suite and
    // in production by the Jira webhook since build 02.
    WebhookSecretStore.injectedSecrets = new Map<String, String>{
      WebhookSecretStore.developerNameFor(gid) => secret
    };

    Test.startTest();
    String readBack = WebhookSecretStore.activeSecretFor(gid);
    Boolean registered = WebhookSecretStore.isRegistered(gid);
    Test.stopTest();

    Assert.areEqual(
      secret,
      readBack,
      'The caller needs the key in a variable to hand to Crypto.verifyHMac.'
    );
    Assert.isTrue(registered, 'And the same fact, without revealing it.');
  }

  @IsTest
  static void anUnpromotedOrUnknownWebhookHasNoSecret() {
    String staged = resourceId();
    WebhookSecretStore.stage(staged, SYSTEM_ASANA, randomSecret());
    WebhookSecretStore.injectedSecrets = new Map<String, String>();

    Test.startTest();
    String neverPromoted = WebhookSecretStore.activeSecretFor(staged);
    String unknown = WebhookSecretStore.activeSecretFor(resourceId());
    String blank = WebhookSecretStore.activeSecretFor('');
    String none = WebhookSecretStore.activeSecretFor(null);
    Test.stopTest();

    Assert.isNull(
      neverPromoted,
      'Staging is not registering. Until the secret is promoted to Custom Metadata the ' +
      'endpoint rejects deliveries, which is the honest answer - it cannot verify them.'
    );
    Assert.isNull(unknown, 'A webhook nobody registered has no secret.');
    Assert.isNull(blank, 'And neither does a blank id.');
    Assert.isNull(
      none,
      'Nor a null one - the caller rejects, it does not crash.'
    );
  }

  @IsTest
  static void aResourceIdBecomesOneStableMetadataName() {
    String gid = '1211234567890';

    Assert.areEqual(
      WebhookSecretStore.developerNameFor(gid),
      WebhookSecretStore.developerNameFor(gid),
      'Derived, not stored, so the endpoint and the promotion script cannot disagree.'
    );
    Assert.isTrue(
      WebhookSecretStore.developerNameFor(gid).startsWith('Webhook_'),
      'A DeveloperName cannot start with a digit, and a gid always does.'
    );
    Assert.areEqual(
      WebhookSecretStore.developerNameFor('12-99/ab'),
      WebhookSecretStore.developerNameFor('12_99_ab'),
      'Anything not a letter, digit or underscore is replaced, so a gid that picked up stray ' +
      'characters cannot produce a name that silently fails to deploy.'
    );
    Assert.isTrue(
      WebhookSecretStore.developerNameFor('9'.repeat(80)).length() <= 40,
      'DeveloperNames cap at 40 characters.'
    );
    Assert.isNull(WebhookSecretStore.developerNameFor('   '));
    Assert.isNull(WebhookSecretStore.developerNameFor(null));
  }

  // ---------- the platform behaviour the design rests on ----------

  /**
   * A site guest can write a custom object row and can never read one back.
   *
   * Pinned here because it is the reason secrets are verified from Custom Metadata rather than
   * from the field they are staged in, and because every plausible fix was tried and none worked:
   * object access, field-level security, view-all, and a `without sharing` class in system mode.
   * Granting each in turn moved the error along - "sObject type not supported", then "No such
   * column", then a silent null - and none produced a readable row.
   */
  @IsTest
  static void theGuestCanStageASecretAndCanNeverReadOneBack() {
    User guest = siteGuest();
    Assert.isNotNull(
      guest,
      'This org serves a public site, so it has a guest user. If this ever fails on a fresh ' +
      'scratch org with no site, make this test conditional rather than deleting it.'
    );

    String gid = resourceId();
    String secret = randomSecret();
    Boolean wrote = false;
    Integer readable = -1;

    Test.startTest();
    System.runAs(guest) {
      wrote = WebhookSecretStore.stage(gid, SYSTEM_ASANA, secret);
      // Not WITH USER_MODE. This is the plainest system-mode read Apex offers, from a class
      // declared without sharing, against a row this very user just created.
      readable = [
        SELECT COUNT()
        FROM Webhook_Secret__c
        WHERE Resource_Id__c = :gid
      ];
    }
    Test.stopTest();

    Assert.isTrue(
      wrote,
      'The handshake write is the one thing the guest can do here.'
    );
    Assert.areEqual(
      0,
      readable,
      'And it cannot read the row back. Not in user mode, not in system mode, not by owning ' +
        'it. If this ever returns 1, the platform changed and the secret is no longer write-only ' +
        'to the endpoint - revisit where secrets live.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Webhook_Secret__c WHERE Resource_Id__c = :gid],
      'The row is really there; it is the guest that cannot see it.'
    );
  }

  // ---------- what actually protects the field ----------

  @IsTest
  static void theBoardGuestSetReachesNeitherTheObjectNorTheField() {
    // Portfolio_HQ_Guest serves the public board. It has no business with secrets, and the two
    // sites share one guest user - so this is the set that must stay clean for the separation
    // to mean anything the day they do not.
    List<ObjectPermissions> objectGrants = [
      SELECT SobjectType
      FROM ObjectPermissions
      WHERE
        SobjectType = 'Webhook_Secret__c'
        AND ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Portfolio_HQ_Guest'
        )
    ];
    Assert.areEqual(
      0,
      objectGrants.size(),
      'The board guest set granted the secret object: ' + objectGrants
    );

    List<FieldPermissions> fieldGrants = [
      SELECT Field
      FROM FieldPermissions
      WHERE
        SobjectType = 'Webhook_Secret__c'
        AND ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Portfolio_HQ_Guest'
        )
    ];
    Assert.areEqual(
      0,
      fieldGrants.size(),
      'The board guest set granted a field on the secret object: ' + fieldGrants
    );
  }

  @IsTest
  static void theWebhookGuestSetCanCreateButNeverEditOrDelete() {
    List<ObjectPermissions> grants = [
      SELECT
        PermissionsCreate,
        PermissionsEdit,
        PermissionsDelete,
        PermissionsViewAllRecords,
        PermissionsModifyAllRecords
      FROM ObjectPermissions
      WHERE
        SobjectType = 'Webhook_Secret__c'
        AND ParentId IN (
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Jira_Webhook_Guest'
        )
    ];
    Assert.areEqual(1, grants.size(), 'The endpoint set grants the object.');
    Assert.isTrue(grants[0].PermissionsCreate, 'Staging is the point.');
    Assert.isFalse(
      grants[0].PermissionsEdit,
      'Edit would let an unauthenticated caller replace a live secret. The guest licence ' +
      'refuses it outright, and the permission set must not ask.'
    );
    Assert.isFalse(grants[0].PermissionsDelete, 'Nor delete one.');
    Assert.isFalse(grants[0].PermissionsViewAllRecords, 'Nor see them all.');
    Assert.isFalse(grants[0].PermissionsModifyAllRecords, 'Nor modify them.');
  }

  /**
   * No reachable Apex hands a secret to a browser.
   *
   * Field-level security and sharing are not the control on this path: the guest cannot write
   * Apex but it can invoke it, and Apex runs in system mode. The code is the control, so the code
   * is what is asserted - every deployed class that mentions a secret is checked for @AuraEnabled.
   */
  @IsTest
  static void noAuraEnabledClassTouchesASecret() {
    List<ApexClass> classes = [SELECT Name, Body FROM ApexClass];
    Assert.isFalse(classes.isEmpty(), 'Apex bodies should be readable here.');

    List<String> offenders = new List<String>();
    for (ApexClass cls : classes) {
      if (cls.Body == null || cls.Name.endsWith('Test')) {
        continue;
      }
      // Comments are stripped first. WebhookSecretStore's own documentation explains why it is
      // never @AuraEnabled, and a naive substring search reads that explanation as the violation
      // it warns against - which is how this assertion first failed.
      String code = stripComments(cls.Body);
      Boolean touchesSecret =
        code.contains('Webhook_Secret__c') ||
        code.contains('Secret__c') ||
        code.contains('Secret_Value__c');
      if (touchesSecret && code.contains('@AuraEnabled')) {
        offenders.add(cls.Name);
      }
    }
    Assert.areEqual(
      new List<String>(),
      offenders,
      'A class both exposes @AuraEnabled methods and touches a secret. Class access is per ' +
        'class, not per method, so that is one permission grant away from publishing a secret ' +
        'to a browser.'
    );
  }

  /** Drops whole-line comments, so prose about a rule is not mistaken for breaking it. */
  private static String stripComments(String body) {
    List<String> kept = new List<String>();
    for (String line : body.split('\n')) {
      String trimmed = line.trim();
      if (
        trimmed.startsWith('//') ||
        trimmed.startsWith('*') ||
        trimmed.startsWith('/*')
      ) {
        continue;
      }
      kept.add(line);
    }
    return String.join(kept, '\n');
  }
}
