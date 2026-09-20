/**
 * Vendor value mappings, read in both directions from one table.
 *
 * Inbound turns an Asana section gid into a Status__c; outbound turns a Status__c back into the
 * section gid to move a task to. Both read these records, which is the whole point: two tables
 * drift, and drift here means inbound and outbound disagree about what a status means, which
 * shows up as a task that moves and then moves back.
 *
 * Vendor-neutral by construction. This class knows there are systems, mapping kinds, external
 * values and normalized values; it does not know what a section is. What a given external value
 * means is the adapter's business, and the adapter is the only caller.
 *
 * Records are custom metadata, so they cannot be created by DML and a test can never stand one
 * up. Tests inject instead - see `injected`.
 */
public with sharing class FieldMappingService {
  /** Mapping_Type__c values. */
  public static final String STATUS = 'Status';
  public static final String TYPE = 'Type';

  // Custom metadata records cannot be inserted, so this is the only way a test can exercise a
  // populated table. Test context only.
  @TestVisible
  private static List<Field_Mapping__mdt> injected;

  // Built once per transaction. The table is small and read repeatedly - once per event for a
  // status, again per item on the way out - and custom metadata reads are not free.
  private static Map<String, String> normalizedByExternal;
  private static Map<String, String> externalByNormalized;
  private static Map<String, String> labelByExternal;

  /**
   * The Work_Item__c value an external value means, or null when nothing maps it.
   *
   * Null rather than a fallback, deliberately. What an unmapped value should become differs by
   * field - an unmapped status is Unspecified, an unmapped type may be left alone entirely - and
   * that is a decision for the caller who knows which field it is filling.
   */
  public static String normalizedFor(
    String sourceSystem,
    String mappingType,
    String externalValue
  ) {
    load();
    return normalizedByExternal.get(
      key(sourceSystem, mappingType, externalValue)
    );
  }

  /**
   * The external value that means a given Work_Item__c value - the same records, read backwards,
   * which is what an outbound push needs to know where to move a task to.
   *
   * Ambiguity resolves to nothing. Several external values may legitimately normalize onto one
   * Salesforce value (two Asana sections could both mean Done), and picking one of them to push
   * to would be a guess that silently moves work to the wrong column.
   */
  public static String externalValueFor(
    String sourceSystem,
    String mappingType,
    String normalizedValue
  ) {
    load();
    return externalByNormalized.get(
      key(sourceSystem, mappingType, normalizedValue)
    );
  }

  /** What the vendor calls an external value, for a log row a person has to read. */
  public static String labelFor(
    String sourceSystem,
    String mappingType,
    String externalValue
  ) {
    load();
    return labelByExternal.get(key(sourceSystem, mappingType, externalValue));
  }

  /** Reset between tests that inject different tables. */
  @TestVisible
  private static void reset() {
    normalizedByExternal = null;
    externalByNormalized = null;
    labelByExternal = null;
  }

  private static void load() {
    if (normalizedByExternal != null) {
      return;
    }
    normalizedByExternal = new Map<String, String>();
    externalByNormalized = new Map<String, String>();
    labelByExternal = new Map<String, String>();

    List<Field_Mapping__mdt> rows = injected != null
      ? injected
      : [
          SELECT
            External_System__c,
            Mapping_Type__c,
            External_Value__c,
            External_Label__c,
            Normalized_Value__c,
            Is_Active__c
          FROM Field_Mapping__mdt
          WHERE Is_Active__c = TRUE
        ];

    Set<String> ambiguousReverse = new Set<String>();
    for (Field_Mapping__mdt row : rows) {
      if (
        row.Is_Active__c != true ||
        String.isBlank(row.External_Value__c) ||
        String.isBlank(row.Normalized_Value__c)
      ) {
        continue;
      }
      String forwardKey = key(
        row.External_System__c,
        row.Mapping_Type__c,
        row.External_Value__c
      );
      normalizedByExternal.put(forwardKey, row.Normalized_Value__c.trim());
      labelByExternal.put(forwardKey, row.External_Label__c);

      String reverseKey = key(
        row.External_System__c,
        row.Mapping_Type__c,
        row.Normalized_Value__c
      );
      if (externalByNormalized.containsKey(reverseKey)) {
        // Two external values claiming one Salesforce value. Legal on the way in, unusable on
        // the way out - see externalValueFor.
        ambiguousReverse.add(reverseKey);
      } else {
        externalByNormalized.put(reverseKey, row.External_Value__c.trim());
      }
    }
    for (String ambiguous : ambiguousReverse) {
      externalByNormalized.remove(ambiguous);
    }
  }

  /** Case-insensitive, whitespace-tolerant. A gid pasted with a stray space still matches. */
  private static String key(
    String sourceSystem,
    String mappingType,
    String value
  ) {
    return ExternalSystem.namespaceOf(sourceSystem) +
      '|' +
      (mappingType == null ? '' : mappingType.trim().toLowerCase()) +
      '|' +
      (value == null ? '' : value.trim().toLowerCase());
  }

  private FieldMappingService() {
  }
}
