/**
 * Webhook_Event__c.Processing_Status__c picklist values - the lifecycle of one inbound delivery.
 *
 * PENDING is set by the endpoint for a verified delivery and is the only state the subscriber
 * picks up. FAILED is set by the endpoint for a rejected signature and by the processor for a
 * payload it could not apply. IGNORED is a success: the delivery was understood and deliberately
 * not applied, because something newer was already held.
 */
public class DeliveryStatus {
  public static final String PENDING = 'Pending';
  public static final String PROCESSING = 'Processing';
  public static final String PROCESSED = 'Processed';
  public static final String IGNORED = 'Ignored';
  public static final String FAILED = 'Failed';

  private DeliveryStatus() {
  }
}
