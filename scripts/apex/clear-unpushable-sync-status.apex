/**
 * Clear the sync state of work items that have no remote record.
 *
 *   sf apex run --file scripts/apex/clear-unpushable-sync-status.apex --target-org MyScratchOrg
 *
 * One-off, build 08 step 7. A work item with no External_Id__c can never push -
 * WorkItemTriggerHandler only stages a record that has one - so Pending on it is a claim that
 * something is on its way when nothing is. The seed canary WI-0011 has shown Pending since it
 * was planted, because the seed wrote Pending and nothing could ever replace it.
 *
 * Both boards already show no sync state for such a record (step 5). This makes the record
 * itself agree, which matters now the internal board links to the record page.
 *
 * Writes Sync_Status__c and Sync_Error__c only. Neither is a field the trigger pushes, and no
 * record here has a remote record to push to, so nothing reaches Jira or Asana. Never Status__c.
 */

List<Work_Item__c> stuck = [
  SELECT Id, Name, Sync_Status__c
  FROM Work_Item__c
  WHERE External_Id__c = NULL AND (Sync_Status__c != NULL OR Sync_Error__c != NULL)
];

for (Work_Item__c item : stuck) {
  System.debug('>>> clearing ' + item.Name + ' (was ' + item.Sync_Status__c + ')');
  item.Sync_Status__c = null;
  item.Sync_Error__c = null;
}
update stuck;

System.debug('>>> cleared ' + stuck.size() + ' work item(s) with no remote record');
