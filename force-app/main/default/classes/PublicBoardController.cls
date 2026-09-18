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
  private static final String EPIC = WorkItemType.EPIC;
  private static final String DONE = WorkItemStatus.DONE;
  private static final Integer COMPLETED_EPIC_LIMIT = 3;
  // Real Jira hierarchies run three deep (epic > story > subtask). Ten is slack, not a
  // guess at the data - it exists to terminate a malformed chain, not to fit a real one.
  private static final Integer MAX_ANCESTOR_DEPTH = 10;

  /**
   * Both views, in one call.
   *
   * The toggle between them is display only: this method takes no parameters, the client
   * cannot select a view, and both payloads are sent regardless of which one is on screen.
   * That is the whole reason the epic DTO is held to the same standard as the work item one -
   * what renders is not what ships.
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
      Map<Id, Work_Item__c> byId = new Map<Id, Work_Item__c>(records);

      // Resolved once per row and reused by both views, so the walk cost does not double.
      // Epics are deliberately absent from this map: an epic is not under itself, and
      // leaving it out is what stops an epic counting towards its own children.
      Map<Id, Id> epicIdByItemId = new Map<Id, Id>();
      for (Work_Item__c record : records) {
        if (record.Type__c != EPIC) {
          epicIdByItemId.put(record.Id, epicAncestorOf(record, byId));
        }
      }

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

        if (record.Type__c == EPIC) {
          // The epic view owns these. An epic is not a task.
          continue;
        }

        Id epicId = epicIdByItemId.get(record.Id);
        Boolean visible;
        if (epicId == null) {
          // Orphan. Visible only while unfinished. Real unparented work stays on the board,
          // but finished orphans would pile up into exactly the unbounded Done column the
          // two-view design exists to avoid.
          visible = record.Status__c != DONE;
        } else {
          // Under an epic. Every status shows, Done included, so a finished task stays
          // visible for as long as the epic it belongs to is still in flight.
          visible = byId.get(epicId).Status__c != DONE;
        }
        if (visible) {
          board.items.add(toCard(record, numberById));
        }
      }

      board.epics = buildEpics(records, epicIdByItemId);
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

  /**
   * The nearest ancestor whose Type__c is 'Epic', or null when there is none.
   *
   * Iterative and bounded twice over, walking rows already in memory. Parent_Work_Item__c is a
   * self-lookup and nothing in the schema prevents a loop, so a visited set catches a cycle of
   * any length - including length one, where a row is its own parent - and the depth cap
   * catches a chain longer than any real hierarchy. Both degrade to "orphan" rather than
   * throwing: a malformed hierarchy should not take the public board down.
   *
   * The map holds public rows only, so a chain passing through a withheld ancestor stops there
   * and the item reads as an orphan. That is build 05's rule applied upwards, and it means an
   * epic's child count can legitimately disagree with Jira.
   */
  private static Id epicAncestorOf(
    Work_Item__c item,
    Map<Id, Work_Item__c> byId
  ) {
    Set<Id> visited = new Set<Id>{ item.Id };
    Id cursor = item.Parent_Work_Item__c;
    Integer depth = 0;
    while (cursor != null && depth < MAX_ANCESTOR_DEPTH) {
      if (!visited.add(cursor)) {
        return null;
      }
      Work_Item__c node = byId.get(cursor);
      if (node == null) {
        return null;
      }
      if (node.Type__c == EPIC) {
        return node.Id;
      }
      cursor = node.Parent_Work_Item__c;
      depth++;
    }
    return null;
  }

  /**
   * Epic cards: active ones first, then at most the three most recently updated completed ones.
   *
   * Counts are computed from rows already loaded, so no query is issued per epic and the query
   * count does not move when the number of epics does.
   *
   * They count public descendants only, because those are the only rows loaded. An epic with
   * ten children of which three are public reads "of 3". Querying the true total would publish
   * the existence of records the visitor cannot see, which build 05 ruled out for parent
   * linkage; the same reasoning applies to a count.
   *
   * A descendant counts towards the epic it resolves to, not towards its immediate parent, so
   * a subtask two hops down still counts. That keeps the number on the card equal to the number
   * of cards the task view shows underneath it.
   */
  private static List<PublicEpic> buildEpics(
    List<Work_Item__c> records,
    Map<Id, Id> epicIdByItemId
  ) {
    Map<Id, Integer> totalByEpic = new Map<Id, Integer>();
    Map<Id, Integer> doneByEpic = new Map<Id, Integer>();
    List<Work_Item__c> active = new List<Work_Item__c>();
    List<Work_Item__c> completed = new List<Work_Item__c>();

    for (Work_Item__c record : records) {
      if (record.Type__c != EPIC) {
        continue;
      }
      // Seeded at zero so an epic with no children still reports 0 of 0 rather than null.
      totalByEpic.put(record.Id, 0);
      doneByEpic.put(record.Id, 0);
      if (record.Status__c == DONE) {
        completed.add(record);
      } else {
        active.add(record);
      }
    }

    for (Work_Item__c record : records) {
      Id epicId = epicIdByItemId.get(record.Id);
      if (epicId == null || !totalByEpic.containsKey(epicId)) {
        continue;
      }
      totalByEpic.put(epicId, totalByEpic.get(epicId) + 1);
      if (record.Status__c == DONE) {
        doneByEpic.put(epicId, doneByEpic.get(epicId) + 1);
      }
    }

    completed.sort(new ByLastModifiedDesc());

    List<PublicEpic> result = new List<PublicEpic>();
    // Active epics keep the query's Name order. Completed ones are the recent tail, capped -
    // an unbounded list of finished epics is the same failure as an unbounded Done column.
    for (Work_Item__c record : active) {
      result.add(toEpic(record, totalByEpic, doneByEpic));
    }
    for (Integer i = 0; i < completed.size() && i < COMPLETED_EPIC_LIMIT; i++) {
      result.add(toEpic(completed[i], totalByEpic, doneByEpic));
    }
    return result;
  }

  /** Most recently updated first. */
  private class ByLastModifiedDesc implements Comparator<Work_Item__c> {
    public Integer compare(Work_Item__c a, Work_Item__c b) {
      if (a.LastModifiedDate == b.LastModifiedDate) {
        return 0;
      }
      return a.LastModifiedDate > b.LastModifiedDate ? -1 : 1;
    }
  }

  private static PublicEpic toEpic(
    Work_Item__c record,
    Map<Id, Integer> totalByEpic,
    Map<Id, Integer> doneByEpic
  ) {
    PublicEpic epic = new PublicEpic();
    // No fallback to the auto number or the external key when the title is blank. The epic
    // DTO carries four fields and nothing else; an untitled epic is the component's problem
    // to label, not a reason to widen what an anonymous visitor receives.
    epic.title = record.Title__c;
    epic.status = record.Status__c;
    epic.totalChildren = totalByEpic.get(record.Id);
    epic.completedChildren = doneByEpic.get(record.Id);
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
    card.lastSyncedAt = record.Last_Synced__c;
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

  /**
   * Exactly what an anonymous visitor receives for an epic. Four fields.
   *
   * No Salesforce id, no auto number, no external key, no description, no project. The list
   * component keys its rows on the array index rather than on anything from here, which is
   * why no identifier is needed and therefore none is published.
   *
   * Both views ship on every call whichever one is on screen, so this is held to the same
   * standard as PublicCard and its key set is asserted exactly for the same reason.
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
  }
}
