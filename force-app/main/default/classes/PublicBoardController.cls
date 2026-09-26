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
  private static final String UNMAPPED = WorkItemType.UNSPECIFIED;

  /**
   * Both views, in one call.
   *
   * The toggle between them is display only: this method takes no parameters, the client
   * cannot select a view, and both payloads are sent regardless of which one is on screen.
   * The epic rules - which epic a task belongs to, what the task view keeps, which epics show -
   * live in EpicRollup, which the internal board uses too.
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
      EpicRollup rollup = new EpicRollup(records);

      PublicBoardData board = new PublicBoardData();
      board.items = new List<PublicCard>();
      Set<String> projectLabels = new Set<String>();

      for (Work_Item__c record : records) {
        // Freshness and the project heading describe the whole public data set, not the
        // filtered view. "Last updated" jumping backwards because a view hid the newest
        // row would be a lie about the data rather than about the view.
        if (
          record.Last_Synced__c != null &&
          (board.lastSyncedAt == null ||
          record.Last_Synced__c > board.lastSyncedAt)
        ) {
          board.lastSyncedAt = record.Last_Synced__c;
        }
        if (
          record.Project__r != null &&
          String.isNotBlank(record.Project__r.Short_Name__c)
        ) {
          projectLabels.add(record.Project__r.Short_Name__c);
        }
        if (rollup.keptInPublicTaskView(record)) {
          board.items.add(toCard(record, numberById));
        }
      }

      board.epics = new List<PublicEpic>();
      for (EpicRollup.Epic epic : rollup.epics()) {
        board.epics.add(toEpic(epic));
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

  private static PublicEpic toEpic(EpicRollup.Epic source) {
    PublicEpic epic = new PublicEpic();
    // No fallback to the auto number or the external key when the title is blank: the epic
    // payload carries no identifier, and an untitled epic is the component's to label.
    epic.title = source.record.Title__c;
    epic.status = source.record.Status__c;
    epic.totalChildren = source.totalChildren;
    epic.completedChildren = source.completedChildren;
    BoardSourceRules.Source rules = BoardSourceRules.forSystem(
      source.record.External_System__c
    );
    epic.sourceLabel = rules.label;
    epic.accentToken = rules.accentToken;
    return epic;
  }

  private static PublicCard toCard(
    Work_Item__c record,
    Map<Id, String> numberById
  ) {
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

    BoardSourceRules.Source rules = BoardSourceRules.forSystem(
      record.External_System__c
    );
    card.condensesIntoEpic = rules.condensesIntoEpics;
    card.sourceLabel = rules.label;
    card.accentToken = rules.accentToken;

    card.createdAt = record.Source_Created__c;
    // Calendar days as YYYY-MM-DD strings, never as a Date the browser would read as UTC
    // midnight - the previous day west of Greenwich.
    card.startDate = IsoDate.format(record.Start_Date__c);
    card.dueDate = IsoDate.format(record.Due_Date__c);
    // Build 09: the label to show and the number to sort on. The order lives in
    // WorkItemPriority, read from the picklist, so the client never compares a name.
    card.priority = WorkItemPriority.labelOf(record.Priority__c);
    card.priorityRank = WorkItemPriority.rankOf(record.Priority__c);
    return card;
  }

  public class PublicBoardData {
    @AuraEnabled
    public List<PublicCard> items { get; set; }
    @AuraEnabled
    public List<PublicEpic> epics { get; set; }
    @AuraEnabled
    public Integer itemCount { get; set; }
    @AuraEnabled
    public String projectLabel { get; set; }
    @AuraEnabled
    public Datetime lastSyncedAt { get; set; }
  }

  /**
   * Exactly what an anonymous visitor receives. Anything not listed here cannot reach them,
   * whatever the query selects or the page renders. PublicBoardControllerTest asserts the key
   * set exactly, so every field below was added on purpose, with that assertion failing first.
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

    /**
     * Whether the epic view replaces this card with the epic it belongs to. Build 07 step 9.
     * The client needs the decision, not a vendor to branch on.
     */
    @AuraEnabled
    public Boolean condensesIntoEpic { get; set; }

    /**
     * What the board calls this card's source, e.g. "Jira". Build 08 step 5, and a reversal:
     * build 07 kept every vendor name away from an anonymous visitor, and this publishes one.
     * It is rendered, never compared - see docs/adr/build-08-board-redesign.md, decision 1.
     */
    @AuraEnabled
    public String sourceLabel { get; set; }

    /** The source's colour token, e.g. "accent-1" - a name the stylesheet maps, never a colour. */
    @AuraEnabled
    public String accentToken { get; set; }

    /** When the work was created in its source system. An instant, so a Datetime. */
    @AuraEnabled
    public Datetime createdAt { get; set; }

    /** YYYY-MM-DD, or null. A calendar day, so a string. */
    @AuraEnabled
    public String startDate { get; set; }

    /** YYYY-MM-DD, or null. */
    @AuraEnabled
    public String dueDate { get; set; }

    /**
     * The priority's label, or null for none. Build 09 step 5, added with the key-set assertion
     * failing first. Epics carry none: EpicRollup does not roll priority up (decision 7).
     */
    @AuraEnabled
    public String priority { get; set; }

    /** 1, 2 or 3 in priority order, or null for none: what the client sorts on (decision 6). */
    @AuraEnabled
    public Integer priorityRank { get; set; }

    // lastSyncedAt was here until build 08 step 5. The card's "Updated" line was its only
    // reader and the redesign removes that line; the board-level lastSyncedAt stays for the
    // header. Removing a field is a narrowing, and the key-set assertion recorded it.
  }

  /**
   * Exactly what an anonymous visitor receives for an epic. No Salesforce id, no auto number, no
   * external key, no description, no project: the list component keys epic rows on their
   * position, so no identifier is needed and none is published.
   *
   * Both views ship on every call whichever is on screen, so this is held to the same standard
   * as PublicCard and its key set is asserted exactly for the same reason.
   */
  public class PublicEpic {
    @AuraEnabled
    public String title { get; set; }
    @AuraEnabled
    public String status { get; set; }
    @AuraEnabled
    public Integer totalChildren { get; set; }
    @AuraEnabled
    public Integer completedChildren { get; set; }

    /**
     * The epic's source label and accent token, build 08 step 5. Without them the source filter
     * could not place an epic card, and an epic would be the one card with no accent.
     */
    @AuraEnabled
    public String sourceLabel { get; set; }
    @AuraEnabled
    public String accentToken { get; set; }
  }
}
