/**
 * The systems Portfolio HQ syncs work from, in both spellings each one has.
 *
 * The picklist value (External_System global value set: 'Jira', 'Asana') is what a record and a
 * webhook delivery carry. The namespace ('jira', 'asana') is what qualifies an External_Id__c
 * and what WorkItemAdapterFactory routes on. They are the same word in different cases, and
 * namespaceOf is the one place that relationship is written down.
 */
public class ExternalSystem {
  public static final String JIRA = 'Jira';
  public static final String ASANA = 'Asana';

  public static final String JIRA_NAMESPACE = 'jira';
  public static final String ASANA_NAMESPACE = 'asana';

  /**
   * @param picklistValue a value from the External_System global value set, e.g. 'Jira'
   * @return              the namespace used in External_Id__c and by the adapter factory
   */
  public static String namespaceOf(String picklistValue) {
    return picklistValue == null ? null : picklistValue.trim().toLowerCase();
  }

  private ExternalSystem() {
  }
}
