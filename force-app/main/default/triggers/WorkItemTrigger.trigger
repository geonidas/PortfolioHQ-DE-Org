/**
 * Outbound push on a genuine change to a pushable field, and the start date rule.
 *
 * before insert and before update refuse a start date the source cannot hold. before update also
 * records which pushable fields changed and marks the record Pending; after update enqueues the
 * push. Both halves are needed: the push sends exactly the fields staged, so without the staging
 * step it would have nothing to send - and would report success while doing nothing.
 */
trigger WorkItemTrigger on Work_Item__c(
  before insert,
  before update,
  after update
) {
  if (Trigger.isBefore) {
    WorkItemTriggerHandler.enforceSourceCapabilities(
      Trigger.new,
      Trigger.oldMap
    );
    if (Trigger.isUpdate) {
      WorkItemTriggerHandler.stageForPush(Trigger.new, Trigger.oldMap);
    }
  } else {
    WorkItemTriggerHandler.pushChanges(Trigger.new, Trigger.oldMap);
  }
}
