/**
 * Everything Portfolio HQ asks of the system that owns a work item, in both directions.
 *
 * No vendor vocabulary appears here or in the types it exchanges. Jira's workflow names,
 * transition ids, payload shape and URL paths live inside the implementing class and nowhere
 * else, so adding an Asana adapter is a new class rather than an edit to callers.
 */
public interface IWorkItemAdapter {
  /**
   * Move a work item to a normalized Status__c value in the external system.
   * Never throws for a business outcome - an unavailable transition comes back in the result.
   *
   * @param item         the work item, which must carry a qualified External_Id__c
   * @param targetStatus a normalized Work_Item__c.Status__c value, never Unspecified
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
   * Turn one raw inbound delivery into a vendor-neutral change.
   *
   * The payload shape is the vendor's business, so parsing lives here rather than in the
   * processor that applies the result. Never throws: a payload that cannot be applied comes back
   * with `failure` set, and the processor fails that one delivery and carries on with the rest.
   *
   * @param rawPayload the delivery body exactly as stored on Webhook_Event__c
   * @return           the change, with failure set when the payload is unusable
   */
  InboundChange parseInbound(String rawPayload);

  /**
   * Translate a status name as the external system spells it into our normalized
   * Work_Item__c.Status__c vocabulary.
   *
   * The inverse direction already lives in the adapter, and both must read from one table -
   * two tables drift, and drift here means inbound and outbound disagree about what a status
   * means. An unrecognised remote status returns Unspecified rather than throwing, which is
   * the same catch-all behaviour the outbound path relies on.
   *
   * @param remoteStatusName status name from the external system, e.g. Jira's 'Resolved'
   * @return                 a Work_Item__c.Status__c value, never null
   */
  String normalizeStatus(String remoteStatusName);

  /**
   * Translate an issue type as the external system spells it into our normalized
   * Work_Item__c.Type__c vocabulary.
   *
   * Here for the same reason normalizeStatus is: 'Sub-task' and 'Story' are Jira's words, and
   * a caller that knew them would be a caller that has to change when a second system arrives.
   * An unrecognised type returns Unspecified rather than throwing - Type__c is a restricted
   * picklist, so a custom issue type must land somewhere, and failing a delivery over a
   * labelling gap would throw away a status change we asked for.
   *
   * @param remoteTypeName issue type name from the external system, e.g. Jira's 'Sub-task'
   * @return               a Work_Item__c.Type__c value, never null
   */
  String normalizeType(String remoteTypeName);

  /**
   * Hand over the Integration_Log__c rows accumulated since the last drain, and clear the buffer.
   *
   * Adapters must not insert these themselves: DML issued between callouts triggers
   * "You have uncommitted work pending" on the next one. The caller buffers across a whole
   * chunk and inserts once, after the last callout.
   */
  List<Integration_Log__c> drainLogs();
}
