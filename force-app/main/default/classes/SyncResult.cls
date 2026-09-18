/**
 * Outcome of one attempted outbound operation on one work item.
 *
 * The point of the Outcome enum is to keep the difference between "the remote system said no"
 * and "the remote system broke" in the type system rather than in string matching. Callers branch
 * on outcome; message is for humans and for Integration_Log__c.
 */
public with sharing class SyncResult {
  public enum Outcome {
    SUCCESS, // transition applied remotely
    ALREADY_IN_TARGET_STATUS, // no callout needed, already there
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

  private SyncResult(Outcome outcome, String message, Integer statusCode) {
    this.outcome = outcome;
    this.message = message;
    this.statusCode = statusCode;
  }

  public static SyncResult success(String appliedStatus, Integer statusCode) {
    SyncResult result = new SyncResult(
      SyncResult.Outcome.SUCCESS,
      'Transitioned to ' + appliedStatus + '.',
      statusCode
    );
    result.appliedStatus = appliedStatus;
    return result;
  }

  public static SyncResult alreadyInTargetStatus(String status) {
    SyncResult result = new SyncResult(
      SyncResult.Outcome.ALREADY_IN_TARGET_STATUS,
      'Already in status ' + status + '; no callout made.',
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
   * True when the work item ended up in the requested status, whether or not that took a callout.
   */
  public Boolean isSuccess() {
    // Qualified with the class name: Apex identifiers are case-insensitive, so inside an
    // instance method the field `outcome` shadows the type `Outcome`.
    return outcome == SyncResult.Outcome.SUCCESS ||
      outcome == SyncResult.Outcome.ALREADY_IN_TARGET_STATUS;
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
