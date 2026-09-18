/**
 * One status change a work item can currently make, described without vendor vocabulary.
 *
 * `id` is opaque - it is whatever the external system needs to identify the transition, and its
 * meaning is the implementing adapter's business. Callers pass it back, they do not interpret it.
 */
public with sharing class TransitionOption {
  public String id { get; private set; }
  public String targetStatus { get; private set; }

  public TransitionOption(String id, String targetStatus) {
    this.id = id;
    this.targetStatus = targetStatus;
  }
}
