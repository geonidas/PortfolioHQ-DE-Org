/**
 * How each source system's work looks and behaves on the board.
 *
 * The board's counterpart to WorkItemAdapterFactory, and the only class that reads
 * Board_Source__mdt. Everything else asks a question here and passes the ANSWER on - a label, an
 * accent token, a boolean - so no component ever branches on which vendor a card came from. A
 * client may show a label; it never compares one.
 *
 * Until build 08 the one rule here, condensesIntoEpics, was a hardcoded set of namespaces. It
 * reads the metadata now like every other answer, so there is one mechanism for per-source rules
 * rather than two drifting apart - the lesson build 07 learned from Jira's STATUS_ALIASES sitting
 * beside Asana's Field_Mapping__mdt.
 *
 * Read with getAll(), which issues no SOQL. The public board is held to one query per anonymous
 * request and asks this class a question for every card.
 */
public with sharing class BoardSourceRules {
  // Custom metadata records cannot be inserted, so this is the only way a test can stand up a
  // table of its own. Test context only; everything else reads the deployed records.
  @TestVisible
  private static List<Board_Source__mdt> injected;

  // Built once per transaction, keyed on the namespace ('jira'), so 'Jira', 'jira' and ' Jira '
  // all find the same record.
  private static Map<String, Source> byNamespace;

  /**
   * Everything the board knows about one source. A value, not a record: callers get answers,
   * not a row they could start reading fields from.
   */
  public class Source {
    /** What the board calls the source, e.g. 'Jira'. Never null. */
    public String label { get; private set; }
    /** A token name such as 'accent-1', or null, which renders neutral. Never a colour. */
    public String accentToken { get; private set; }
    public Boolean supportsStartDate { get; private set; }
    public Boolean condensesIntoEpics { get; private set; }

    private Source(
      String label,
      String accentToken,
      Boolean supportsStartDate,
      Boolean condensesIntoEpics
    ) {
      this.label = label;
      this.accentToken = accentToken;
      this.supportsStartDate = supportsStartDate == true;
      this.condensesIntoEpics = condensesIntoEpics == true;
    }
  }

  /**
   * The rules for one source system.
   *
   * A system with no record is not an error. It gets the safe answer to every question: its own
   * picklist value as a label, no accent, no start dates, and flat. Flat is never wrong - a card
   * that does not condense is shown as itself - where wrongly condensing one would hide it behind
   * an epic it does not belong to. A new source therefore inherits nothing by accident.
   *
   * @param sourceSystem a Work_Item__c.External_System__c value, e.g. 'Jira'. Null or blank is
   *                     a record with no source, and gets a blank label.
   */
  public static Source forSystem(String sourceSystem) {
    load();
    String namespace = ExternalSystem.namespaceOf(sourceSystem);
    Source known = String.isBlank(namespace)
      ? null
      : byNamespace.get(namespace);
    if (known != null) {
      return known;
    }
    return new Source(
      sourceSystem == null ? '' : sourceSystem.trim(),
      null,
      false,
      false
    );
  }

  /** True when work from this system rolls up into epics on the epic view. */
  public static Boolean condensesIntoEpics(String sourceSystem) {
    return forSystem(sourceSystem).condensesIntoEpics;
  }

  /**
   * True when this system can hold a start date. Apex refuses a start date on anything else;
   * hiding the editor is presentation, this is the rule.
   */
  public static Boolean supportsStartDate(String sourceSystem) {
    return forSystem(sourceSystem).supportsStartDate;
  }

  /** Reset between tests that inject different tables. */
  @TestVisible
  private static void reset() {
    byNamespace = null;
  }

  private static void load() {
    if (byNamespace != null) {
      return;
    }
    byNamespace = new Map<String, Source>();
    List<Board_Source__mdt> rows = injected != null
      ? injected
      : Board_Source__mdt.getAll().values();
    for (Board_Source__mdt row : rows) {
      String namespace = ExternalSystem.namespaceOf(row.External_System__c);
      if (String.isBlank(namespace)) {
        continue;
      }
      byNamespace.put(
        namespace,
        new Source(
          String.isBlank(row.Display_Label__c)
            ? row.External_System__c.trim()
            : row.Display_Label__c.trim(),
          String.isBlank(row.Accent_Token__c)
            ? null
            : row.Accent_Token__c.trim(),
          row.Supports_Start_Date__c,
          row.Condenses_Into_Epics__c
        )
      );
    }
  }

  private BoardSourceRules() {
  }
}
