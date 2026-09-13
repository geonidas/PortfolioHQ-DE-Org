/**
 * Queries for Project__c. Separate from WorkItemSelector by object, which is the convention this
 * build establishes.
 */
public with sharing class ProjectSelector {
  /**
   * @return the project, or null when the id is blank or the user cannot see it. Null is a
   *         normal answer: an unscoped board has no project at all.
   */
  public static Project__c byId(Id projectId) {
    if (projectId == null) {
      return null;
    }
    List<Project__c> found = Database.queryWithBinds(
      'SELECT Id, Name, Short_Name__c, Status__c FROM Project__c WHERE Id = :projectId',
      new Map<String, Object>{ 'projectId' => projectId },
      AccessLevel.USER_MODE
    );
    return found.isEmpty() ? null : found[0];
  }

  /**
   * Card label for a project. Short_Name__c is the intended label, but it is optional and is
   * currently blank on the only project in this org, so Name is the fallback - an empty label
   * on every card would be worse than a long one.
   */
  public static String labelFor(Project__c project) {
    if (project == null) {
      return null;
    }
    return String.isNotBlank(project.Short_Name__c)
      ? project.Short_Name__c
      : project.Name;
  }
}
