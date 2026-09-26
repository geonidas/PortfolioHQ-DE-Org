/**
 * Priority__c's order and its words, read from the picklist itself (build 09).
 *
 * The one place the priority order lives. Both boards send priorityRank - 1, 2, 3 - beside the
 * label, so a client sorts on a number and never compares a priority's name (ADR build-09,
 * decisions 2 and 6). Nothing here names a priority either: the order is the picklist's own, so
 * reordering or relabelling the values in Setup changes both boards without a code change.
 *
 * Read once per transaction. The public board asks this for every card, on a guest request held
 * to one SOQL query - and a describe is not a query.
 */
public with sharing class WorkItemPriority {
  private static Map<String, Integer> rankByValue;
  private static Map<String, String> labelByValue;

  /** 1 for the first active picklist value, 2 for the next; null for blank or an unknown value. */
  public static Integer rankOf(String value) {
    load();
    return String.isBlank(value) ? null : rankByValue.get(value.toLowerCase());
  }

  /** What the picklist calls the value, for display; null for blank or an unknown value. */
  public static String labelOf(String value) {
    load();
    return String.isBlank(value) ? null : labelByValue.get(value.toLowerCase());
  }

  private static void load() {
    if (rankByValue != null) {
      return;
    }
    rankByValue = new Map<String, Integer>();
    labelByValue = new Map<String, String>();
    Integer rank = 0;
    for (
      Schema.PicklistEntry entry : Work_Item__c.Priority__c.getDescribe()
        .getPicklistValues()
    ) {
      if (!entry.isActive()) {
        continue;
      }
      rank++;
      rankByValue.put(entry.getValue().toLowerCase(), rank);
      labelByValue.put(entry.getValue().toLowerCase(), entry.getLabel());
    }
  }

  private WorkItemPriority() {
  }
}
