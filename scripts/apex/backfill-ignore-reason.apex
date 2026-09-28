/**
 * Set Ignore_Reason__c on rows that reached Ignored before the field existed.
 *
 *   sf apex run --file scripts/apex/backfill-ignore-reason.apex --target-org MyScratchOrg
 *
 * One-off. New rows get the value from WorkItemInboundProcessor.superseded and
 * WorkItemInboundSweeper, so this is only for history written before those existed.
 *
 * It string-matches Error_Message__c, which is exactly the fragility the field was added to
 * remove - acceptable once, over rows whose messages are already written and can no longer
 * change. Anything it cannot classify is left null rather than guessed at, and reported.
 *
 * Writes no Work_Item__c field, so nothing syncs to Jira or Asana.
 */

List<Webhook_Event__c> rows = [
  SELECT Id, Error_Message__c
  FROM Webhook_Event__c
  WHERE
    Processing_Status__c = :DeliveryStatus.IGNORED
    AND Ignore_Reason__c = NULL
];

List<Webhook_Event__c> updates = new List<Webhook_Event__c>();
Integer superseded = 0;
Integer notApplicable = 0;
Integer unclassified = 0;

for (Webhook_Event__c row : rows) {
  String message = row.Error_Message__c == null ? '' : row.Error_Message__c;
  String reason = null;
  if (message.contains('Superseded within the same batch')) {
    reason = IgnoreReason.SUPERSEDED;
    superseded++;
  } else if (message.contains('Retired by WorkItemInboundSweeper')) {
    reason = IgnoreReason.NOT_APPLICABLE;
    notApplicable++;
  } else {
    unclassified++;
  }
  if (reason != null) {
    updates.add(new Webhook_Event__c(Id = row.Id, Ignore_Reason__c = reason));
  }
}

if (!updates.isEmpty()) {
  update updates;
}

System.debug(
  LoggingLevel.INFO,
  '>>> Ignored rows with no reason: ' + rows.size()
);
System.debug(LoggingLevel.INFO, '>>> Set Superseded: ' + superseded);
System.debug(LoggingLevel.INFO, '>>> Set Not Applicable: ' + notApplicable);
System.debug(
  LoggingLevel.INFO,
  '>>> Left null (message matched neither pattern): ' + unclassified
);
