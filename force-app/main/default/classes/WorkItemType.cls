/**
 * Work_Item__c.Type__c picklist values.
 *
 * UNSPECIFIED is only ever the catch-all for a remote type with no mapping; nothing maps to it
 * deliberately, which keeps "we have not mapped this" distinguishable from a real value.
 */
public class WorkItemType {
  public static final String UNSPECIFIED = 'Unspecified';
  public static final String EPIC = 'Epic';
  public static final String STORY = 'Story';
  public static final String BUG = 'Bug';
  public static final String TASK = 'Task';
  public static final String SPIKE = 'Spike';

  private WorkItemType() {
  }
}
