/**
 * One inbound change to a work item, in vendor-neutral terms.
 *
 * An adapter's parseInbound turns a raw delivery into one of these; WorkItemInboundProcessor
 * applies it without knowing what the payload looked like. Nothing here is Jira vocabulary: the
 * remote status and type are the vendor's words only so a log row can name them, and the
 * normalized fields beside them are what actually gets written.
 *
 * The rule for the optional fields is "null means the delivery did not carry it", never "the
 * remote value is empty". The processor assigns a field only when it is non-null, because most
 * deliveries are status transitions carrying nothing else, and writing a null through would blank
 * known data on every one of them.
 */
public class InboundChange {
  /** The delivery's own event name, e.g. jira:issue_updated. Recorded, not acted on. */
  public String eventType;

  /** Namespaced, e.g. jira:10039. The upsert key. Required. */
  public String externalId;

  /** The vendor's human key, e.g. DOPP-15. Optional. */
  public String externalKey;

  /** The task's name, already cut to the Title__c field length. Null when not carried. */
  public String title;

  /** Status as the vendor spells it, for logging. */
  public String remoteStatus;

  /** A Work_Item__c.Status__c value. Never null on a usable change; Unspecified when unmapped. */
  public String normalizedStatus;

  /** Issue type as the vendor spells it, for logging. */
  public String remoteType;

  /** A Work_Item__c.Type__c value. Null when the delivery carried no usable type. */
  public String normalizedType;

  /** Namespaced parent reference, e.g. jira:10038. Null when not carried. */
  public String parentExternalId;

  /**
   * The vendor's project key, e.g. DOPP, matched against Project__c.External_Project_Key__c.
   * Null when not carried.
   */
  public String projectKey;

  /** When the remote record last changed, per the vendor. Required - it drives loop prevention. */
  public Datetime remoteUpdated;

  /** Non-null when the payload cannot be applied. The processor fails the delivery with it. */
  public String failure;

  public Boolean isUsable() {
    return failure == null;
  }
}
