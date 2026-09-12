/**
 * Outbound operations against whatever system owns a work item.
 *
 * No vendor vocabulary appears here or in the types it exchanges. Jira's workflow names,
 * transition ids and URL shapes live inside the implementing class and nowhere else, so adding
 * an Asana adapter later is a new class rather than an edit to callers.
 */
public interface IWorkItemAdapter {
    /**
     * Move a work item to a normalized Status__c value in the external system.
     * Never throws for a business outcome - an unavailable transition comes back in the result.
     *
     * @param item         the work item, which must carry a qualified External_Id__c
     * @param targetStatus a normalized Work_Item__c.Status__c value, never 'Unspecified'
     */
    SyncResult updateStatus(Work_Item__c item, String targetStatus);

    /**
     * Status changes currently reachable from the item's present state.
     *
     * @param externalId qualified external id, e.g. jira:10023
     * @return           reachable transitions, empty if the item is terminal
     * @throws AdapterException on a technical failure, so an empty list unambiguously means
     *                          "nowhere to go" rather than "the call broke"
     */
    List<TransitionOption> fetchAvailableTransitions(String externalId);

    /**
     * Hand over the Integration_Log__c rows accumulated since the last drain, and clear the buffer.
     *
     * Adapters must not insert these themselves: DML issued between callouts triggers
     * "You have uncommitted work pending" on the next one. The caller buffers across a whole
     * chunk and inserts once, after the last callout.
     */
    List<Integration_Log__c> drainLogs();
}