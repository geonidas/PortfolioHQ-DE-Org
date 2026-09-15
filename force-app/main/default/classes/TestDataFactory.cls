/**
 * Builds Project__c and Work_Item__c records for tests.
 *
 * Every method returns a List so callers can exercise bulk paths, and takes a doInsert flag
 * so a test that needs to mutate records before DML can get them uncommitted.
 *
 * Work item External_Id__c values are namespaced (jira:...) to match the production convention.
 * The namespace is not decoration: External_Id__c is unique per field, not per external system,
 * so an unprefixed Jira issue ID could collide with an Asana GID that happens to match.
 *
 * Records are built with Status__c = Unspecified and Sync_Status__c = Pending. That pairing is
 * deliberate - it is the only combination that is both the field defaults and legal under the
 * Sync_Status_Requires_Known_Status validation rule, so bulk inserts never fail on it. Tests
 * that want other values should pass doInsert = false and set them before DML.
 *
 * Assignee__c is left null. Creating Users inside a test alongside custom-object DML raises
 * MIXED_DML_OPERATION, so assignment belongs in tests that opt into it with System.runAs.
 */
@IsTest
public class TestDataFactory {
  private static final String EXTERNAL_ID_NAMESPACE = 'jira';

  // Random per transaction so two calls within one test can never collide on the unique key.
  private static final String RUN_TOKEN = String.valueOf(Crypto.getRandomLong())
    .replace('-', '');

  private static Integer workItemSequence = 0;

  /**
   * @param count    how many projects to build
   * @param doInsert commit them before returning
   * @return the built projects, with Ids populated when doInsert is true
   */
  public static List<Project__c> createProjects(
    Integer count,
    Boolean doInsert
  ) {
    List<Project__c> projects = new List<Project__c>();
    for (Integer i = 0; i < count; i++) {
      projects.add(
        new Project__c(
          Name = 'Test Project ' + i,
          Short_Name__c = 'PRJ-' + i,
          Status__c = 'Planning',
          External_System__c = 'Jira',
          External_Project_Key__c = 'DOPP',
          GitHub_URL__c = 'https://github.com/example/portfolio-hq',
          Is_Public__c = false
        )
      );
    }
    if (doInsert) {
      insert projects;
    }
    return projects;
  }

  /**
   * @param count     how many work items to build
   * @param projectId parent project, or null to build orphans
   * @param doInsert  commit them before returning
   * @return the built work items, each with a unique External_Id__c
   */
  public static List<Work_Item__c> createWorkItems(
    Integer count,
    Id projectId,
    Boolean doInsert
  ) {
    List<Work_Item__c> workItems = new List<Work_Item__c>();
    for (Integer i = 0; i < count; i++) {
      Integer issueNumber = i + 1;
      workItems.add(
        new Work_Item__c(
          External_Id__c = nextExternalId(),
          External_Key__c = 'DOPP-' + issueNumber,
          External_URL__c = 'https://example.atlassian.net/browse/DOPP-' +
            issueNumber,
          External_System__c = 'Jira',
          Title__c = 'Seeded work item ' + issueNumber,
          Project__c = projectId,
          Type__c = 'Unspecified',
          Status__c = 'Unspecified',
          Sync_Status__c = 'Pending',
          Story_Points__c = Math.mod(i, 8) + 0.5,
          Description__c = 'Seeded by TestDataFactory for work item ' + i,
          Is_Public__c = false
        )
      );
    }
    if (doInsert) {
      insert workItems;
    }
    return workItems;
  }

  /**
   * Namespaced, run-unique external id. Exposed so a test can build an upsert payload that
   * deliberately does not match an existing record.
   */
  public static String nextExternalId() {
    workItemSequence++;
    return EXTERNAL_ID_NAMESPACE + ':' + RUN_TOKEN + '-' + workItemSequence;
  }
}
