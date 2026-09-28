/**
 * Promote staged webhook signing secrets into protected Custom Metadata.
 *
 * Run once per webhook registration, immediately after the curl that registers it:
 *   sf apex run --file scripts/apex/promote-webhook-secret.apex --target-org MyScratchOrg
 *
 * Why this step exists at all. The registration handshake is the only moment a vendor ever sends
 * its signing secret, and it sends it to the endpoint - which runs as the site guest. A guest can
 * write a custom object row and can NEVER read one back: not its own, not in system mode, not
 * through a `without sharing` class. So the endpoint stages the secret on Webhook_Secret__c and
 * stops. Verification, which also runs as the guest, reads protected Custom Metadata instead,
 * because Apex reads that with no object grant, no field-level security and no sharing rule -
 * the same mechanism the Jira webhook has used since build 02.
 *
 * Apex cannot write Custom Metadata synchronously, and the guest could not deploy it in any case,
 * so something run by a real user has to carry the value across. That is this script.
 *
 * It never prints a secret. It reports the resource id, the DeveloperName it deployed to, and the
 * deployment's job id. Until the deployment finishes, deliveries for that webhook are rejected
 * with a 401 and the vendor retries - Asana tolerates 24 hours of failures before deleting a
 * webhook, so running this straight after registering is comfortably inside the window.
 *
 * Writes no Work_Item__c field, so WorkItemTrigger stages nothing and enqueues nothing.
 * Safe to re-run: a secret already promoted is deployed again with the same value.
 */

List<Webhook_Secret__c> staged = [
  SELECT Id, Resource_Id__c, Source_System__c, Secret__c, Active__c
  FROM Webhook_Secret__c
  WHERE Active__c = TRUE
  ORDER BY CreatedDate ASC
];

if (staged.isEmpty()) {
  System.debug(
    LoggingLevel.INFO,
    '>>> No active staged secrets. Nothing to promote.'
  );
} else {
  Metadata.DeployContainer container = new Metadata.DeployContainer();
  List<String> promoted = new List<String>();

  for (Webhook_Secret__c row : staged) {
    String developerName = WebhookSecretStore.developerNameFor(
      row.Resource_Id__c
    );
    if (developerName == null || String.isBlank(row.Secret__c)) {
      System.debug(
        LoggingLevel.ERROR,
        '>>> SKIPPED resource=' +
          row.Resource_Id__c +
          ' - unusable resource id, or no secret on the row. Nothing was deployed for it.'
      );
      continue;
    }

    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = 'Integration_Secret__mdt.' + developerName;
    record.label = Strings.truncate(
      (row.Source_System__c == null ? 'Webhook' : row.Source_System__c) +
        ' ' +
        row.Resource_Id__c,
      40
    );

    Metadata.CustomMetadataValue secretValue = new Metadata.CustomMetadataValue();
    secretValue.field = 'Secret_Value__c';
    secretValue.value = row.Secret__c;
    record.values.add(secretValue);

    Metadata.CustomMetadataValue activeValue = new Metadata.CustomMetadataValue();
    activeValue.field = 'Is_Active__c';
    activeValue.value = true;
    record.values.add(activeValue);

    container.addMetadata(record);
    // The resource id and the target name only. Never the value.
    promoted.add(row.Resource_Id__c + ' -> ' + developerName);
  }

  if (promoted.isEmpty()) {
    System.debug(
      LoggingLevel.ERROR,
      '>>> Nothing promotable. See the SKIPPED lines above.'
    );
  } else {
    Id jobId = Metadata.Operations.enqueueDeployment(container, null);
    for (String line : promoted) {
      System.debug(LoggingLevel.INFO, '>>> PROMOTING ' + line);
    }
    System.debug(LoggingLevel.INFO, '>>> Deployment job: ' + jobId);
    System.debug(
      LoggingLevel.INFO,
      '>>> Deployments are asynchronous. Check Setup > Deployment Status, then confirm with:' +
      ' sf data query -o MyScratchOrg -q "SELECT DeveloperName, Is_Active__c FROM Integration_Secret__mdt"'
    );
    System.debug(
      LoggingLevel.INFO,
      '>>> Once a secret is promoted and verified working, DELETE its Webhook_Secret__c row.' +
      ' The staged row has done its job and is the only copy sitting in a queryable field.'
    );
  }
}
