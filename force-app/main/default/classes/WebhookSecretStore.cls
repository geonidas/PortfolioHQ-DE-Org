/**
 * The only place an inbound webhook signing secret is staged or read.
 *
 * Two halves, because the platform forces them apart. A site guest can WRITE a custom object row
 * and can never READ one back - not its own, not in system mode, not through a `without sharing`
 * class. That is the Guest User Security Policy, and it is not configuration: granting object
 * access, field-level security and view-all in turn each moved the error along and none of them
 * produced a readable row. Measured, not assumed; the build 07 report has the sequence.
 *
 * So:
 *
 * - stage() writes. It runs in the guest's transaction during the registration handshake, which
 *   is the only moment the vendor ever sends the secret, and it is the only write.
 * - activeSecretFor() reads, and reads from protected Custom Metadata rather than from the row
 *   that was staged. Apex reads protected Custom Metadata with no object grant, no field-level
 *   security and no sharing rule, from any user including the guest - which this org has been
 *   relying on since build 02, because it is how the Jira webhook verifies today.
 * - Nothing promotes one to the other automatically. scripts/apex/promote-webhook-secret.apex
 *   does it, run by hand beside the curl that registers the webhook. Custom Metadata cannot be
 *   written synchronously from Apex, and the guest could not deploy it in any case.
 *
 * The result is stronger than the field-level security this started as. There is no mode in which
 * the guest can read a secret: not user mode, not system mode, not by owning the row. The staged
 * row is write-only to the user that writes it.
 *
 * `without sharing` is for the promotion read, which must see staged rows whoever owns them. It
 * is deliberately NOT what makes the guest path work - nothing makes the guest path read a row,
 * and that is the point.
 *
 * What still holds, and is still the real control on the Apex path:
 *
 * - No method here is @AuraEnabled, and none ever should be. The guest cannot write Apex but it
 *   can invoke it, and Apex runs in system mode, so a method that returned a secret would hand
 *   it over whatever the permissions said.
 * - The secret is read into a local variable and handed to Crypto.verifyHMac. Never onto a
 *   wrapper, never into a logging helper, never System.debug'd, never into Integration_Log__c.
 *
 * The production shape remains what the build 07 report describes: terminate the webhook at a
 * gateway, verify there against a secret manager, and forward to Salesforce over OAuth JWT so
 * the platform never holds the secret at all.
 */
public without sharing class WebhookSecretStore {
  private static final Integer SECRET_MAX = Webhook_Secret__c.Secret__c.getDescribe()
    .getLength();
  private static final Integer RESOURCE_ID_MAX = Webhook_Secret__c.Resource_Id__c.getDescribe()
    .getLength();

  /** Custom Metadata DeveloperNames must start with a letter, so a numeric gid needs a prefix. */
  private static final String NAME_PREFIX = 'Webhook_';
  private static final Integer DEVELOPER_NAME_MAX = 40;

  // Custom metadata records cannot be created by DML, so a test can never stand one up. The
  // only way to exercise a verified read is to inject. Test context only.
  @TestVisible
  private static Map<String, String> injectedSecrets;

  /**
   * The active secret for one webhook, or null when there is none to use.
   *
   * Fails closed, always, and for one indistinguishable reason. A webhook nobody registered, one
   * whose secret was never promoted, one an operator deactivated and one whose value is blank all
   * return null, and null means reject. There is no path on which "not configured" degrades into
   * "skip verification".
   *
   * @param resourceId the vendor's identifier for the webhook, e.g. an Asana resource gid
   * @return           the secret, or null - never an exception, and never a partial answer
   */
  public static String activeSecretFor(String resourceId) {
    String developerName = developerNameFor(resourceId);
    if (developerName == null) {
      return null;
    }
    if (injectedSecrets != null) {
      return injectedSecrets.get(developerName);
    }
    return IntegrationSecretService.activeSecret(developerName);
  }

  /** True when this webhook has a usable secret. Never reveals the value. */
  public static Boolean isRegistered(String resourceId) {
    return activeSecretFor(resourceId) != null;
  }

  /**
   * The Custom Metadata DeveloperName a webhook's secret is promoted to.
   *
   * Derived rather than stored, so the endpoint, the promotion script and any later reconciliation
   * cannot disagree about where a secret lives. Anything not a letter, digit or underscore is
   * replaced, because a gid that picked up stray characters must not produce a name that silently
   * fails to deploy.
   *
   * @return null when the resource id is unusable, which the caller treats as "reject"
   */
  public static String developerNameFor(String resourceId) {
    if (String.isBlank(resourceId)) {
      return null;
    }
    String cleaned = resourceId.trim().replaceAll('[^A-Za-z0-9_]', '_');
    if (String.isBlank(cleaned)) {
      return null;
    }
    return Strings.truncate(NAME_PREFIX + cleaned, DEVELOPER_NAME_MAX);
  }

  /**
   * Record the secret a vendor handed over during registration, so an operator can promote it.
   *
   * Insert only, never an upsert. Two reasons, and the second is the one that matters. The guest
   * user licence forbids Edit on a custom object outright - the permission set will not even
   * deploy with it - so an update is not available on this path. And first-write-wins is the
   * safer rule anyway: this endpoint is unauthenticated, so an upsert would let anyone who knows
   * a resource gid replace the real secret with one of their own and then sign whatever they
   * liked. A second registration for a resource that already has a row fails on the unique key,
   * the caller answers non-2xx, and registration does not complete. Rotating means deleting the
   * old row first, deliberately and by hand.
   *
   * @return true when the row was written; false is a rejection the caller must answer with a
   *         non-2xx, because completing a handshake whose secret was not recorded registers a
   *         webhook that can never be verified
   */
  public static Boolean stage(
    String resourceId,
    String sourceSystem,
    String secret
  ) {
    if (String.isBlank(resourceId) || String.isBlank(secret)) {
      return false;
    }
    if (secret.length() > SECRET_MAX) {
      // Truncating would record a key that verifies nothing, which is worse than refusing: the
      // handshake would answer 200 and every later delivery would fail its signature.
      return false;
    }
    // Deliberately no length floor. A vendor that shortens its secret is not this class's
    // business, and refusing a handshake over a guess at how long a key should be would take
    // the integration down for a reason nobody could find.
    List<Database.SaveResult> results = Database.insert(
      new List<Webhook_Secret__c>{
        new Webhook_Secret__c(
          Resource_Id__c = resourceId.trim().left(RESOURCE_ID_MAX),
          Source_System__c = sourceSystem,
          Secret__c = secret,
          Active__c = true
        )
      },
      false
    );
    // Deliberately not logged on failure. A DML error message on this object can quote the row,
    // and the row carries the secret.
    return results[0].isSuccess();
  }
}
