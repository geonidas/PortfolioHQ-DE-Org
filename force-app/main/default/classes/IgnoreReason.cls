/**
 * Webhook_Event__c.Ignore_Reason__c picklist values.
 *
 * Ignored is a success, but it covers two outcomes that a retention rule has to tell apart, and
 * until this field existed the only way to do that was to string-match Error_Message__c - a rule
 * that breaks silently the day somebody rewords a message.
 */
public class IgnoreReason {
  /** A newer delivery for the same external id won inside the batch. The winner has the story. */
  public static final String SUPERSEDED = 'Superseded';

  /**
   * The adapter had nothing to say about the resource, so no retry would ever produce a change.
   * Asana story events - a comment, a section change - are the bulk of these.
   */
  public static final String NOT_APPLICABLE = 'Not Applicable';

  private IgnoreReason() {
  }
}
