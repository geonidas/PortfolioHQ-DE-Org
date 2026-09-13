/**
 * Read side of the work item board.
 *
 * Built for two audiences from the start. Today it sits on an internal Lightning page; in build 05
 * the same method is called by a site guest user. That is why every query runs in USER_MODE and
 * why nothing here assumes an authenticated context - retrofitting either would be worse than
 * starting correct.
 *
 * Columns are not this class's business. The component decides which statuses to show and in what
 * order; the controller returns every record the user can see and lets the view bucket them. That
 * is what makes adding a status a configuration change rather than a deployment.
 */
public with sharing class WorkItemBoardController {
  /**
   * Everything the board needs, in one round trip.
   *
   * @param projectId scope to one project, or blank for every work item the user can see
   */
  @AuraEnabled(cacheable=true)
  public static BoardData getBoardData(Id projectId) {
    try {
      List<Work_Item__c> items = WorkItemSelector.forBoard(projectId);
      Project__c project = ProjectSelector.byId(projectId);

      BoardData board = new BoardData();
      board.items = items;
      board.itemCount = items.size();
      board.projectId = projectId;
      board.projectLabel = ProjectSelector.labelFor(project);
      board.lastSyncedAt = mostRecentSync(items);
      return board;
    } catch (Exception e) {
      // A raw exception reaches the client as an opaque server error. Converting it gives
      // the component something it can actually render in its error state.
      throw new AuraHandledException(
        'Could not load the board: ' + e.getMessage()
      );
    }
  }

  /**
   * Move one work item to a new status.
   *
   * Writes Status__c and nothing else. WorkItemTrigger does the rest: it stages Sync_Status__c
   * as Pending and enqueues the outbound push. This method deliberately does NOT call
   * WorkItemSyncService - doing so would either throw, because a callout cannot follow DML in
   * the same transaction, or push twice, because the trigger has already queued one.
   *
   * The push is asynchronous and the result says so. Salesforce is updated when this returns;
   * Jira is not yet.
   *
   * @param workItemId the record to move
   * @param newStatus  a Status__c value; never Unspecified, which means "no Jira mapping"
   */
  @AuraEnabled
  public static StatusChangeResult changeStatus(
    Id workItemId,
    String newStatus
  ) {
    if (workItemId == null) {
      throw new AuraHandledException('No work item was supplied.');
    }
    if (String.isBlank(newStatus)) {
      throw new AuraHandledException('No status was supplied.');
    }
    if (newStatus == 'Unspecified') {
      throw new AuraHandledException(
        'Unspecified means Jira reported a status we cannot map, so it cannot be chosen here.'
      );
    }

    try {
      List<Work_Item__c> found = WorkItemSelector.byIds(
        new Set<Id>{ workItemId }
      );
      if (found.isEmpty()) {
        throw new AuraHandledException(
          'That work item is not available to you.'
        );
      }

      Work_Item__c current = found[0];
      StatusChangeResult result = new StatusChangeResult();
      result.workItemId = workItemId;

      if (current.Status__c == newStatus) {
        result.status = current.Status__c;
        result.syncStatus = current.Sync_Status__c;
        result.pushQueued = false;
        result.message = 'Already ' + newStatus + '. Nothing was changed.';
        return result;
      }

      // Counting queued jobs across the DML is direct evidence that the trigger fired,
      // rather than an assumption that it did.
      Integer jobsBefore = Limits.getQueueableJobs();
      Database.update(
        new Work_Item__c(Id = workItemId, Status__c = newStatus),
        AccessLevel.USER_MODE
      );
      result.pushQueued = Limits.getQueueableJobs() > jobsBefore;

      Work_Item__c saved = WorkItemSelector.byIds(new Set<Id>{ workItemId })[0];
      result.status = saved.Status__c;
      result.syncStatus = saved.Sync_Status__c;
      result.message = result.pushQueued
        ? 'Saved in Salesforce. The Jira update is running in the background.'
        : 'Saved in Salesforce. No Jira push was queued for this record.';
      return result;
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(
        'Could not change the status: ' + e.getMessage()
      );
    }
  }

  /**
   * Most recent Last_Synced__c across the set, or null when nothing has ever synced.
   *
   * Computed from the records already in memory rather than with an aggregate query: the rows
   * are right here, and a second query would be a second thing that can fail.
   */
  private static Datetime mostRecentSync(List<Work_Item__c> items) {
    Datetime latest;
    for (Work_Item__c item : items) {
      if (
        item.Last_Synced__c != null &&
        (latest == null ||
        item.Last_Synced__c > latest)
      ) {
        latest = item.Last_Synced__c;
      }
    }
    return latest;
  }

  /**
   * What the component receives. A wrapper rather than a bare list because the board needs three
   * things that are not properties of any single record: which project it is showing, how fresh
   * the data is, and whether "no cards" means an empty project or a failed filter.
   */
  public class BoardData {
    @AuraEnabled
    public List<Work_Item__c> items { get; set; }
    @AuraEnabled
    public Integer itemCount { get; set; }
    @AuraEnabled
    public Id projectId { get; set; }
    /** Short_Name__c where set, Name otherwise. Null when the board is not project-scoped. */
    @AuraEnabled
    public String projectLabel { get; set; }
    @AuraEnabled
    public Datetime lastSyncedAt { get; set; }
  }

  /**
   * What the component gets back. syncStatus is the honest part: it will read Pending, because
   * the push has been queued and has not run yet.
   */
  public class StatusChangeResult {
    @AuraEnabled
    public Id workItemId { get; set; }
    @AuraEnabled
    public String status { get; set; }
    @AuraEnabled
    public String syncStatus { get; set; }
    /** True when the trigger queued an outbound push for this change. */
    @AuraEnabled
    public Boolean pushQueued { get; set; }
    @AuraEnabled
    public String message { get; set; }
  }
}
