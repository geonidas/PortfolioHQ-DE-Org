/**
 * Outcome of one attempted outbound operation on one work item.
 *
 * The point of the Outcome enum is to keep the difference between "the remote system said no"
 * and "the remote system broke" in the type system rather than in string matching. Callers branch
 * on outcome; message is for humans and for Integration_Log__c.
 */
public with sharing class SyncResult {
  public enum Outcome {
    SUCCESS, // every requested field applied remotely
    ALREADY_IN_TARGET_STATUS, // the remote status was already the one asked for
    NOTHING_TO_PUSH, // the record had no fields waiting; nothing sent and nothing to write back
    NO_TRANSITION_AVAILABLE, // handled business outcome, not a fault
    BAD_REQUEST, // caller error: unusable status or malformed external id
    UNAUTHORIZED, // 401/403 - token missing, wrong, or principal not granted
    RATE_LIMITED, // 429
    REMOTE_ERROR, // 5xx, or a 4xx we do not model
    CALLOUT_FAILED // no response at all: timeout or CalloutException
  }

  public Outcome outcome { get; private set; }
  public String message { get; private set; }
  public Integer statusCode { get; private set; }
  public Id workItemId { get; set; }
  public String externalId { get; set; }
  public String appliedStatus { get; set; }

  /**
   * The fields the remote system confirmed, which is what the write-back clears from
   * Pending_Push_Fields__c. Set on a failure too, and that is the point of it: a push can land
   * its field edit and have its status transition refused, and forgetting the half that landed
   * would push it again for nothing, while clearing the half that did not would mark a refused
   * change as synced.
   */
  public Set<SyncField> confirmedFields { get; set; }

  /**
   * The source's own timestamp of the record just after this push wrote to it - null when
   * nothing was written, or when the adapter could not learn it.
   *
   * The write-back stamps it on Remote_Last_Modified__c (build 09 step 5). Before, a push left
   * that field where the last delivery had put it, so the echo of an EARLIER push, processed
   * late - after this one had landed - still counted as newer, was applied, and showed the
   * earlier value as Synced until the later echo put it right. Seen live on WI-0003. With the
   * stamp the late echo is older than what the record holds, and the timestamp check retires it.
   */
  public Datetime remoteUpdated { get; set; }

  private SyncResult(Outcome outcome, String message, Integer statusCode) {
    this.outcome = outcome;
    this.message = message;
    this.statusCode = statusCode;
    this.confirmedFields = new Set<SyncField>();
  }

  /** Every field asked for was applied. */
  public static SyncResult pushed(
    Set<SyncField> confirmed,
    Integer statusCode
  ) {
    SyncResult result = new SyncResult(
      SyncResult.Outcome.SUCCESS,
      'Pushed ' + SyncFields.describe(confirmed) + '.',
      statusCode
    );
    result.confirmedFields = new Set<SyncField>(confirmed);
    return result;
  }

  /** A record that reached the push with nothing waiting - an earlier job already sent it. */
  public static SyncResult nothingToPush() {
    return new SyncResult(
      SyncResult.Outcome.NOTHING_TO_PUSH,
      'Nothing was waiting to be pushed.',
      null
    );
  }

  public static SyncResult alreadyInTargetStatus(String status) {
    SyncResult result = new SyncResult(
      SyncResult.Outcome.ALREADY_IN_TARGET_STATUS,
      'Already in status ' +
        status +
        ' in the source system; nothing to transition.',
      null
    );
    result.appliedStatus = status;
    return result;
  }

  public static SyncResult failure(
    Outcome outcome,
    String message,
    Integer statusCode
  ) {
    return new SyncResult(outcome, message, statusCode);
  }

  /**
   * True when everything asked for is now true remotely, whether or not that took a callout.
   */
  public Boolean isSuccess() {
    // Qualified with the class name: Apex identifiers are case-insensitive, so inside an
    // instance method the field `outcome` shadows the type `Outcome`.
    return outcome == SyncResult.Outcome.SUCCESS ||
      outcome == SyncResult.Outcome.ALREADY_IN_TARGET_STATUS ||
      outcome == SyncResult.Outcome.NOTHING_TO_PUSH;
  }

  /**
   * True when the remote system answered normally and simply would not make this change.
   * Distinguishes an expected "no" from a broken integration, which the two get logged as
   * differently and which callers should not retry.
   */
  public Boolean isBusinessOutcome() {
    return outcome == SyncResult.Outcome.NO_TRANSITION_AVAILABLE ||
      outcome == SyncResult.Outcome.BAD_REQUEST;
  }
}
