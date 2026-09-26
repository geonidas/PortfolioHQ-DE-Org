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
  private static List<Option> ordered;

  /** One choice for the internal board's priority editor. */
  public class Option {
    /** What saveDetails is sent: the picklist value. */
    @AuraEnabled
    public String value { get; private set; }
    /** What the editor shows. */
    @AuraEnabled
    public String label { get; private set; }
    /** Its place in the order - the same number a card's priorityRank carries. */
    @AuraEnabled
    public Integer rank { get; private set; }

    private Option(String value, String label, Integer rank) {
      this.value = value;
      this.label = label;
      this.rank = rank;
    }
  }

  /**
   * The active values in priority order, for the editor. The editor adds its own "No priority";
   * no value here means none, because Salesforce stores none as blank (decision 1).
   */
  public static List<Option> options() {
    load();
    return new List<Option>(ordered);
  }

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
    ordered = new List<Option>();
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
      ordered.add(new Option(entry.getValue(), entry.getLabel(), rank));
    }
  }

  private WorkItemPriority() {
  }
}
