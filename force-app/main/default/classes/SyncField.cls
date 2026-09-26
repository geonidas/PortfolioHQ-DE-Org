/**
 * The Work_Item__c fields Salesforce pushes to a source system, in Salesforce's own terms.
 *
 * What an adapter is asked to push. Vendor-neutral on purpose: TITLE is Jira's summary and
 * Asana's name, and saying either word here would put vendor vocabulary above the adapter.
 * Stored by name in Work_Item__c.Pending_Push_Fields__c, so a value renamed here strands every
 * record that has it pending - add, never rename.
 */
public enum SyncField {
  STATUS,
  TITLE,
  START_DATE,
  DUE_DATE,
  // Build 09. Declared in step 2 so inbound can hold a pending priority back; nothing stages it
  // until SyncFields.changedBetween compares Priority__c (step 3).
  PRIORITY
}
