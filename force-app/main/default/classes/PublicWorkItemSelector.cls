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
        Project__r.Short_Name__c,
        // Build 08: the created, start and due dates a card shows. Each is on the guest
        // permission set by name, and GuestAccessTest asserts that list exactly.
        Source_Created__c,
        Start_Date__c,
        Due_Date__c,
        // Build 09: the priority a card shows and sorts by. Same query, same one-query budget.
        Priority__c,
        // Build 10: the two flags the WHERE clause requires, read so FeaturedEpicService applies
        // the same rule here as everywhere else when it resolves the featured epic. Never
        // published - no DTO carries either - and already on the guest's grant, so this widens
        // nothing (GuestAccessTest pins both).
        Is_Public__c,
        Project__r.Is_Public__c,
        // Read, never published as it is. The board asks BoardSourceRules about this system
        // and sends the answers - a label from Board_Source__mdt, an accent token, whether its
        // work condenses into epics - rather than the picklist value.
        External_System__c,
        // Ordering key only, for capping the completed epics on the epic view (EpicRollup).
        // Never published - it is absent from every DTO. LastModifiedDate rather than
        // Remote_Last_Modified__c because it is a standard field needing no field-level
        // grant, and widening Portfolio_HQ_Guest for something the visitor never sees
        // would be a real cost for no benefit.
        LastModifiedDate
      FROM Work_Item__c
      WHERE Is_Public__c = TRUE AND Project__r.Is_Public__c = TRUE
      WITH USER_MODE
      ORDER BY Name ASC
    ];
  }
}
