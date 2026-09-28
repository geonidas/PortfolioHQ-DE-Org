/**
 * Work_Item__c.Sync_Status__c picklist values.
 *
 * SYNCED is a claim that Salesforce and the remote system agree, and it is only ever written by
 * the sync paths themselves. PENDING is what a local status change stages, and what an inbound
 * unmapped status stays at - see the Sync_Status_Requires_Known_Status validation rule.
 */
public class SyncStatus {
  public static final String PENDING = 'Pending';
  public static final String SYNCED = 'Synced';
  public static final String FAILED = 'Failed';

  private SyncStatus() {
  }
}
