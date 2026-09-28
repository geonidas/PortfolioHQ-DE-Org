/**
 * The epic view's rules, shared by both boards: which epic a task rolls up into, how many of an
 * epic's descendants are done, which epics are shown, and which cards the public task view keeps.
 *
 * Moved out of PublicBoardController in build 08 so the internal board's Epics view uses the same
 * rules from the same code, rather than a second copy that would drift - the lesson build 07
 * learned from two status mapping mechanisms. It stays in Apex rather than moving to shared
 * JavaScript because the public board withholds rows the rules read: finished orphans and tasks
 * under a finished epic never reach an anonymous visitor, and a client-side rollup would need them.
 *
 * Works on rows already in memory and issues no query, so the public board stays at one SOQL
 * query per anonymous request however many epics there are. Rows need Id, Type__c, Status__c,
 * Parent_Work_Item__c, External_System__c and LastModifiedDate.
 */
public with sharing class EpicRollup {
  public static final Integer COMPLETED_EPIC_LIMIT = 3;
  // Real Jira hierarchies run three deep (epic > story > subtask). Ten is slack, not a guess at
  // the data - it exists to terminate a malformed chain, not to fit a real one.
  private static final Integer MAX_ANCESTOR_DEPTH = 10;
  private static final String EPIC = WorkItemType.EPIC;
  private static final String DONE = WorkItemStatus.DONE;

  private final List<Work_Item__c> records;
  private final Map<Id, Work_Item__c> byId;
  // Resolved once per row and reused by every question below. Epics are deliberately absent: an
  // epic is not under itself, and leaving it out is what stops one counting towards its own
  // children.
  private final Map<Id, Id> epicIdByItemId = new Map<Id, Id>();
  // Build 10. The epic the public board features, when it is one of these rows, or null.
  private final Id featuredEpicId;

  /** One epic card's worth: the epic and the counts of what rolls up into it. */
  public class Epic {
    public Work_Item__c record { get; private set; }
    public Integer totalChildren { get; private set; }
    public Integer completedChildren { get; private set; }
    /** Build 10: whether this is the epic the public board features. */
    public Boolean isFeatured { get; private set; }

    private Epic(
      Work_Item__c record,
      Integer total,
      Integer completed,
      Boolean isFeatured
    ) {
      this.record = record;
      this.totalChildren = total;
      this.completedChildren = completed;
      this.isFeatured = isFeatured;
    }
  }

  /**
   * @param records every row the board loaded. Only these are walked: a chain passing through a
   *                row that was not loaded - on the public board, a withheld ancestor - stops
   *                there, and the item reads as having no epic.
   */
  public EpicRollup(List<Work_Item__c> records) {
    this(records, null);
  }

  /**
   * @param featuredEpicId the featured epic as the caller resolved it (FeaturedEpicService), or
   *                       null. Ignored unless it is an epic among the rows, so an Id the caller
   *                       did not load features nothing.
   */
  public EpicRollup(List<Work_Item__c> records, Id featuredEpicId) {
    this.records = records == null ? new List<Work_Item__c>() : records;
    this.byId = new Map<Id, Work_Item__c>(this.records);
    this.featuredEpicId = featuredEpicId != null &&
      isEpic(byId.get(featuredEpicId))
      ? featuredEpicId
      : null;
    for (Work_Item__c record : this.records) {
      if (
        !isEpic(record) &&
        BoardSourceRules.condensesIntoEpics(record.External_System__c)
      ) {
        epicIdByItemId.put(record.Id, epicAncestorOf(record));
      }
    }
  }

  /**
   * Whether a row is an epic: what the Epics view makes a card of, what the others roll up into,
   * and - since build 10 - the only kind of row the public board can feature (ADR build-10,
   * decision 3). One definition, so the featured epic and the Epics view cannot disagree about
   * what an epic is.
   */
  public static Boolean isEpic(Work_Item__c record) {
    return record != null && record.Type__c == EPIC;
  }

  /** The epic an item rolls up into, or null when it has none or its source is flat. */
  public Id epicOf(Id itemId) {
    return epicIdByItemId.get(itemId);
  }

  /**
   * Build 10: whether an item rolls up into the featured epic. Membership as the epic's card
   * counts it - every item whose nearest epic this is, not only its direct children (ADR
   * build-10, decision 4, as the owner's answer to step 0's question 2 settled it).
   */
  public Boolean inFeaturedEpic(Id itemId) {
    Id epicId = epicIdByItemId.get(itemId);
    return epicId != null && epicId == featuredEpicId;
  }

  /**
   * Whether the public task view keeps this card.
   *
   * - An epic: never. The epic view owns epics; an epic is not a task.
   * - Work from a flat source: always. It has nothing to belong to, and hiding it the moment it
   *   is finished would make completing something look like deleting it.
   * - Work under an epic: while the epic is still in flight, whatever its own status, so a
   *   finished task stays visible for as long as the epic it belongs to is open. Work under the
   *   featured epic stays after it is Done too, for as long as it is featured (build 10).
   * - Unparented work from a source that has epics: while it is unfinished. Finished orphans
   *   would otherwise pile into exactly the unbounded Done column the two views exist to avoid.
   */
  public Boolean keptInPublicTaskView(Work_Item__c record) {
    if (isEpic(record)) {
      return false;
    }
    if (!BoardSourceRules.condensesIntoEpics(record.External_System__c)) {
      return true;
    }
    Id epicId = epicIdByItemId.get(record.Id);
    if (epicId == null) {
      return record.Status__c != DONE;
    }
    return byId.get(epicId).Status__c != DONE || epicId == featuredEpicId;
  }

  /**
   * Epic cards: active ones first, in the order loaded, then at most the three most recently
   * updated completed ones - an unbounded list of finished epics is the same failure as an
   * unbounded Done column. The featured epic is listed wherever it falls, so a featured epic
   * moved to Done keeps its card - and its indicator and Remove button - however many finished
   * epics are newer (build 10, the owner's answer to step 0's question 3).
   *
   * A descendant counts towards the epic it resolves to, not towards its immediate parent, so a
   * subtask two hops down still counts. On the public board the counts include public rows only,
   * because those are the only rows loaded: an epic with ten children of which three are public
   * reads "of 3". Querying the true total would publish the existence of records the visitor
   * cannot see.
   */
  public List<Epic> epics() {
    Map<Id, Integer> totalByEpic = new Map<Id, Integer>();
    Map<Id, Integer> doneByEpic = new Map<Id, Integer>();
    List<Work_Item__c> active = new List<Work_Item__c>();
    List<Work_Item__c> completed = new List<Work_Item__c>();

    for (Work_Item__c record : records) {
      if (!isEpic(record)) {
        continue;
      }
      // Seeded at zero so an epic with no children reports 0 of 0 rather than null.
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

    List<Epic> result = new List<Epic>();
    for (Work_Item__c record : active) {
      result.add(toEpic(record, totalByEpic, doneByEpic));
    }
    for (Integer i = 0; i < completed.size(); i++) {
      Work_Item__c record = completed[i];
      if (i < COMPLETED_EPIC_LIMIT || record.Id == featuredEpicId) {
        result.add(toEpic(record, totalByEpic, doneByEpic));
      }
    }
    return result;
  }

  private Epic toEpic(
    Work_Item__c record,
    Map<Id, Integer> totalByEpic,
    Map<Id, Integer> doneByEpic
  ) {
    return new Epic(
      record,
      totalByEpic.get(record.Id),
      doneByEpic.get(record.Id),
      record.Id == featuredEpicId
    );
  }

  /**
   * The nearest ancestor whose Type__c is Epic, or null when there is none.
   *
   * Iterative and bounded twice over. Parent_Work_Item__c is a self-lookup and nothing in the
   * schema prevents a loop, so a visited set catches a cycle of any length - including length
   * one, where a row is its own parent - and the depth cap catches a chain longer than any real
   * hierarchy. Both degrade to "no epic" rather than throwing: a malformed hierarchy should not
   * take a board down.
   */
  private Id epicAncestorOf(Work_Item__c item) {
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
      if (isEpic(node)) {
        return node.Id;
      }
      cursor = node.Parent_Work_Item__c;
      depth++;
    }
    return null;
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
}
