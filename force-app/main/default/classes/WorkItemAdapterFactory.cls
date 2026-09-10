/**
 * Chooses the adapter for a work item. This is the one place outside an adapter that is allowed
 * to name a vendor, because something has to construct the concrete class - the rule everywhere
 * else is that business logic never mentions Jira.
 *
 * Routing is by the external id's namespace rather than External_System__c. The namespace is what
 * actually determines which API an id is valid against, it is already required and validated by
 * the adapter, and it keeps one source of truth. External_System__c stays descriptive, for
 * reporting and page layouts.
 */
public with sharing class WorkItemAdapterFactory {
    public class UnsupportedSystemException extends Exception {
    }

    // Set by tests to bypass HTTP entirely when the thing under test is the service, not the wire.
    @TestVisible
    private static IWorkItemAdapter injected;

    /**
     * @param workItem must carry a qualified External_Id__c, e.g. jira:10023
     */
    public static IWorkItemAdapter forWorkItem(Work_Item__c workItem) {
        if (workItem == null) {
            throw new UnsupportedSystemException('No work item supplied.');
        }
        return forSystem(ExternalIdUtil.namespaceOf(workItem.External_Id__c));
    }

    /**
     * @param systemNamespace case-insensitive system key, e.g. 'jira' or the picklist's 'Jira'
     */
    public static IWorkItemAdapter forSystem(String systemNamespace) {
        if (injected != null) {
            return injected;
        }
        String key = systemNamespace == null ? '' : systemNamespace.trim().toLowerCase();
        if (key == 'jira') {
            return new JiraAdapter();
        }
        throw new UnsupportedSystemException('No adapter is registered for external system: ' + systemNamespace);
    }
}
