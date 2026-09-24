/**
 * Queries for Work_Item__c.
 *
 * First selector in this repo - builds 01 to 03 query inline - so it sets the pattern: one class
 * per object, a single field list, and every query in USER_MODE.
 *
 * USER_MODE is not optional here even though this build is internal. The same queries sit behind
 * a guest user in build 05, and a query written in system mode would quietly return fields the
 * guest should never see. Enforcing it now means build 05 fails loudly on a missing grant instead
 * of leaking.
 */
public with sharing class WorkItemSelector {
  /**
   * Everything a board card needs. Assignee__c is deliberately absent: rendering a name means
   * traversing to User, which a guest cannot read, and every assignee is currently null anyway.
   */
  private static final String FIELDS =
    'Id, Name, Title__c, External_Key__c, External_URL__c, Status__c, Type__c, Sync_Status__c, ' +
    'Story_Points__c, Description__c, Last_Synced__c, Remote_Last_Modified__c, ' +
    'Parent_Work_Item__c, Project__c, Project__r.Name, Project__r.Short_Name__c, ' +
    // Build 08: which source the item belongs to and whether it has a remote record, for the
    // save path's rules and messages; the dates it edits; and why the last push failed.
    'External_Id__c, External_System__c, Source_Created__c, Start_Date__c, Due_Date__c, ' +
    // LastModifiedDate orders the completed epics EpicRollup keeps, as on the public board.
    'Sync_Error__c, LastModifiedDate, ' +
    // Build 08 step 8: whether a Failed record has anything left to send again.
    'Pending_Push_Fields__c';

  /**
   * One query, whether or not a project was supplied.
   *
   * @param projectId scope to one project, or null for every work item the user can see -
   *                  a blank project on a board placement means "everything", not "orphans"
   */
  public static List<Work_Item__c> forBoard(Id projectId) {
    String soql = 'SELECT ' + FIELDS + ' FROM Work_Item__c';
    Map<String, Object> binds = new Map<String, Object>();
    if (projectId != null) {
      soql += ' WHERE Project__c = :projectId';
      binds.put('projectId', projectId);
    }
    // Name is the auto number, so this is stable insertion order - the client does the
    // parent/child nesting, it just needs the order not to shift between refreshes.
    soql += ' ORDER BY Name ASC';
    return Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
  }

  /**
   * Used by the status change action to re-read exactly the records it is about to touch.
   */
  public static List<Work_Item__c> byIds(Set<Id> workItemIds) {
    if (workItemIds == null || workItemIds.isEmpty()) {
      return new List<Work_Item__c>();
    }
    return Database.queryWithBinds(
      'SELECT ' +
        FIELDS +
        ' FROM Work_Item__c WHERE Id IN :workItemIds ORDER BY Name ASC',
      new Map<String, Object>{ 'workItemIds' => workItemIds },
      AccessLevel.USER_MODE
    );
  }
}
