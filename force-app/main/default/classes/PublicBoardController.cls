/**
 * Read-only board data for unauthenticated site visitors.
 *
 * Separate from WorkItemBoardController because Apex class access is granted per class, not per
 * method. Any user who can reach a class can invoke every @AuraEnabled method on it from the
 * browser, whatever the page renders - so a guest who could reach WorkItemBoardController could
 * call changeStatus regardless of which component is on the page. This class contains no write
 * method, which makes read-only a property of the code rather than a permission that has to stay
 * correct forever.
 *
 * Two further rules hold here and are worth stating because both are easy to erode:
 *
 * 1. No parameters. Nothing the client sends can change what comes back.
 * 2. No SObjects cross the wire. An SObject carries every queried field to the browser; a DTO
 *    carries only what was chosen. Adding a field to the query does not silently publish it.
 */
public with sharing class PublicBoardController {
  private static final String UNMAPPED = 'Unspecified';

  /**
   * Every public work item, and nothing else.
   */
  @AuraEnabled(cacheable=true)
  public static PublicBoardData getPublicBoardData() {
    try {
      List<Work_Item__c> records = PublicWorkItemSelector.publicBoardItems();

      // Parent linkage resolves to the parent's auto number, and only when that parent is
      // itself public. A child whose parent is withheld simply has no parent - telling an
      // anonymous visitor that a record they cannot see exists is a small leak with no
      // upside.
      Map<Id, String> numberById = new Map<Id, String>();
      for (Work_Item__c record : records) {
        numberById.put(record.Id, record.Name);
      }

      PublicBoardData board = new PublicBoardData();
      board.items = new List<PublicCard>();
      Set<String> projectLabels = new Set<String>();

      for (Work_Item__c record : records) {
        PublicCard card = new PublicCard();
        // Salesforce ids are deliberately not published. The auto number is a stable,
        // non-addressable key, which is all the client needs for list keys and nesting.
        card.recordNumber = record.Name;
        card.title = record.Title__c;
        card.externalKey = record.External_Key__c;
        card.status = record.Status__c;
        card.type = record.Type__c == UNMAPPED ? null : record.Type__c;
        // Short_Name__c only. Falling back to Project__c.Name would publish the internal
        // project name to anyone with the URL.
        card.projectLabel = record.Project__r == null
          ? null
          : record.Project__r.Short_Name__c;
        card.parentNumber = record.Parent_Work_Item__c == null
          ? null
          : numberById.get(record.Parent_Work_Item__c);
        card.syncStatus = record.Sync_Status__c;
        card.lastSyncedAt = record.Last_Synced__c;
        board.items.add(card);

        if (String.isNotBlank(card.projectLabel)) {
          projectLabels.add(card.projectLabel);
        }
        if (
          record.Last_Synced__c != null &&
          (board.lastSyncedAt == null ||
          record.Last_Synced__c > board.lastSyncedAt)
        ) {
          board.lastSyncedAt = record.Last_Synced__c;
        }
      }

      board.itemCount = board.items.size();
      // A heading only when the whole board is one project; otherwise there is no single
      // honest label to show.
      board.projectLabel = projectLabels.size() == 1
        ? new List<String>(projectLabels)[0]
        : null;
      return board;
    } catch (Exception e) {
      // A raw exception reaches the browser as an opaque server error and can carry query
      // and field names with it. The component gets something renderable instead.
      throw new AuraHandledException('The board is unavailable right now.');
    }
  }

  public class PublicBoardData {
    @AuraEnabled
    public List<PublicCard> items { get; set; }
    @AuraEnabled
    public Integer itemCount { get; set; }
    @AuraEnabled
    public String projectLabel { get; set; }
    @AuraEnabled
    public Datetime lastSyncedAt { get; set; }
  }

  /**
   * Exactly what an anonymous visitor receives. Anything not listed here cannot reach them,
   * whatever the query selects or the page renders.
   */
  public class PublicCard {
    @AuraEnabled
    public String recordNumber { get; set; }
    @AuraEnabled
    public String title { get; set; }
    @AuraEnabled
    public String externalKey { get; set; }
    @AuraEnabled
    public String status { get; set; }
    @AuraEnabled
    public String type { get; set; }
    @AuraEnabled
    public String projectLabel { get; set; }
    @AuraEnabled
    public String parentNumber { get; set; }
    @AuraEnabled
    public String syncStatus { get; set; }
    @AuraEnabled
    public Datetime lastSyncedAt { get; set; }
  }
}
