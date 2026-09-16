/**
 * The only query a guest visitor can cause.
 *
 * A separate class from WorkItemSelector on purpose, mirroring the controller split. Build 04's
 * selector takes a project scope and treats a blank one as "return everything" - correct for an
 * internal page, fail-open for a public one. This class has no parameters at all, so there is
 * nothing a caller can pass, omit or mis-default to widen what comes back.
 *
 * The field list is deliberately narrower than the internal one. Description__c, Assignee__c and
 * External_URL__c are absent because they are never sent to an unauthenticated browser, and their
 * absence here is what guarantees it - not a mapping step further downstream that could be edited.
 */
public with sharing class PublicWorkItemSelector {
  /**
   * Both public flags are required, written into the query text rather than composed. Not a
   * parameter, not a page property, not a default - there is no code path that produces an
   * unfiltered result.
   *
   * USER_MODE means a missing guest grant throws instead of quietly returning more.
   */
  public static List<Work_Item__c> publicBoardItems() {
    return [
      SELECT
        Id,
        Name,
        Title__c,
        External_Key__c,
        Status__c,
        Type__c,
        Sync_Status__c,
        Last_Synced__c,
        Parent_Work_Item__c,
        Project__r.Short_Name__c
      FROM Work_Item__c
      WHERE Is_Public__c = TRUE AND Project__r.Is_Public__c = TRUE
      WITH USER_MODE
      ORDER BY Name ASC
    ];
  }
}
