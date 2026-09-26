/**
 * Which pushable fields changed, and the stored form of that set.
 *
 * The one place that decides what counts as a change worth pushing, so the trigger's before and
 * after halves, the sync service and inbound sync cannot disagree about it.
 */
public class SyncFields {
  private static final String SEPARATOR = ';';

  /**
   * The pushable fields that differ between two versions of a record.
   *
   * Status only when it moved to something other than Unspecified: Unspecified means "the source
   * reported a status we cannot map", so there is nothing to ask the source for. The title is
   * compared case-sensitively - Apex's == on strings is not, so "Deep work" to "Deep Work" would
   * otherwise be no change at all and never reach the source.
   *
   * The priority is a picklist, so == is the right comparison: its values differ by more than
   * case. Cleared counts, and pushes as the source's none (build 09).
   *
   * Nothing at all for a record with no External_Id__c: the source has no record to update.
   */
  public static Set<SyncField> changedBetween(
    Work_Item__c item,
    Work_Item__c prior
  ) {
    Set<SyncField> changed = new Set<SyncField>();
    if (item == null || prior == null || String.isBlank(item.External_Id__c)) {
      return changed;
    }
    if (
      item.Status__c != prior.Status__c &&
      item.Status__c != WorkItemStatus.UNSPECIFIED
    ) {
      changed.add(SyncField.STATUS);
    }
    if (!sameText(item.Title__c, prior.Title__c)) {
      changed.add(SyncField.TITLE);
    }
    if (item.Start_Date__c != prior.Start_Date__c) {
      changed.add(SyncField.START_DATE);
    }
    if (item.Due_Date__c != prior.Due_Date__c) {
      changed.add(SyncField.DUE_DATE);
    }
    if (item.Priority__c != prior.Priority__c) {
      changed.add(SyncField.PRIORITY);
    }
    return changed;
  }

  /** Case-sensitive, null-safe. Apex's == on strings ignores case. */
  public static Boolean sameText(String a, String b) {
    return a == null ? b == null : a.equals(b);
  }

  /** Pending_Push_Fields__c to a set. Unknown names are dropped rather than fatal. */
  public static Set<SyncField> parse(String stored) {
    Set<SyncField> fields = new Set<SyncField>();
    if (String.isBlank(stored)) {
      return fields;
    }
    Map<String, SyncField> byName = new Map<String, SyncField>();
    for (SyncField field : SyncField.values()) {
      byName.put(field.name(), field);
    }
    for (String name : stored.split(SEPARATOR)) {
      SyncField field = byName.get(name.trim().toUpperCase());
      if (field != null) {
        fields.add(field);
      }
    }
    return fields;
  }

  /** A set to Pending_Push_Fields__c, in declaration order so equal sets store equally; null when empty. */
  public static String serialize(Set<SyncField> fields) {
    if (fields == null || fields.isEmpty()) {
      return null;
    }
    List<String> names = new List<String>();
    for (SyncField field : SyncField.values()) {
      if (fields.contains(field)) {
        names.add(field.name());
      }
    }
    return String.join(names, SEPARATOR);
  }

  /** Words for a message a person reads, e.g. "title and due date". */
  public static String describe(Set<SyncField> fields) {
    List<String> words = new List<String>();
    for (SyncField field : SyncField.values()) {
      if (fields != null && fields.contains(field)) {
        words.add(field.name().toLowerCase().replace('_', ' '));
      }
    }
    if (words.isEmpty()) {
      return 'nothing';
    }
    if (words.size() == 1) {
      return words[0];
    }
    String last = words.remove(words.size() - 1);
    return String.join(words, ', ') + ' and ' + last;
  }

  private SyncFields() {
  }
}
