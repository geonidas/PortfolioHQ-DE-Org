/**
 * How each source system's work behaves on the board.
 *
 * The board's counterpart to WorkItemAdapterFactory, and named a vendor for the same reason: a
 * system has to be identified somewhere, and the rule everywhere else is that no method branches
 * on which one. Nothing here reaches a browser - PublicBoardController asks this class a question
 * and publishes the ANSWER, a boolean, so the guest payload carries no vendor name at all.
 *
 * One rule so far, and it is the only one build 07 needs.
 *
 * Epics are a Jira shape. A Jira task belongs to an epic, and the epic view condenses tasks into
 * the epics they belong to, because once a project is finished the individual tasks matter less
 * than the epic did. Asana items are flat by design in this build: they have no epic and never
 * will, so there is nothing to condense them into - and that makes them neither epics nor
 * orphans. They render identically in both views.
 *
 * A list of what DOES condense rather than what does not, so a third system added later is flat
 * until somebody decides otherwise, rather than silently inheriting Jira's hierarchy.
 */
public with sharing class BoardSourceRules {
  private static final Set<String> CONDENSES_INTO_EPICS = new Set<String>{
    ExternalSystem.JIRA_NAMESPACE
  };

  /**
   * True when work from this system rolls up into epics on the epic view.
   *
   * False is the default and the safe answer: a card that does not condense is shown as itself
   * in both views, which is never wrong, where wrongly condensing one would hide it behind an
   * epic it does not belong to.
   *
   * @param sourceSystem a Work_Item__c.Source_System__c value, e.g. 'Jira'. Null counts as false.
   */
  public static Boolean condensesIntoEpics(String sourceSystem) {
    String namespace = ExternalSystem.namespaceOf(sourceSystem);
    return String.isNotBlank(namespace) &&
      CONDENSES_INTO_EPICS.contains(namespace);
  }

  private BoardSourceRules() {
  }
}
