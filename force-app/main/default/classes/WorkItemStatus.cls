/**
 * Work_Item__c.Status__c picklist values.
 *
 * One home for the strings that the trigger, the adapters, the inbound processor and both board
 * controllers all compare against. A typo in a literal here is a compile error; a typo in a
 * literal at a call site was a silent no-op, which is the failure mode this class exists to
 * remove. The values are API names, so they must match the picklist metadata exactly.
 */
public class WorkItemStatus {
  /** The default and the landing value for any remote status with no mapping. Never pushed. */
  public static final String UNSPECIFIED = 'Unspecified';
  public static final String TO_DO = 'To Do';
  public static final String IN_PROGRESS = 'In Progress';
  public static final String IN_REVIEW = 'In Review';
  public static final String DONE = 'Done';

  private WorkItemStatus() {
  }
}
