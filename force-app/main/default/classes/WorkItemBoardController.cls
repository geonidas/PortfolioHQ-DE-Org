/**
 * The internal work item board: reads, the status change and the detail save.
 *
 * Internal only. A site guest must never be granted this class - class access is per class, not
 * per method, and this one writes - which is why PublicBoardController exists beside it. Every
 * query still runs in USER_MODE, so a user without a field grant is refused rather than served.
 *
 * Columns are not this class's business. The component decides which statuses to show and in what
 * order; the controller returns every record the user can see and lets the view bucket them. That
 * is what makes adding a status a configuration change rather than a deployment.
 */
public with sharing class WorkItemBoardController {
  /** Grants the board's Open record link. Assigned through Portfolio_HQ_Developer. */
  @TestVisible
  private static final String OPEN_RECORD_PERMISSION = 'Portfolio_HQ_Open_Record';

  /**
   * Everything the board needs, in one round trip: every card, and the epic view built by the
   * same rules the public board uses.
   *
   * Cards, not records. Since build 08 the internal board receives the same shape as the public
   * one - the same property names for the same facts - so the ID line, the dates and the filters
   * are one function each on the client rather than two. The internal card adds what only this
   * board shows: ids for nesting and the record link, the description, the reason a push failed,
   * and whether its source can hold a start date.
   *
   * @param projectId scope to one project, or blank for every work item the user can see
   */
  @AuraEnabled(cacheable=true)
  public static BoardData getBoardData(Id projectId) {
    try {
      List<Work_Item__c> items = WorkItemSelector.forBoard(projectId);
      Project__c project = ProjectSelector.byId(projectId);

      BoardData board = new BoardData();
      board.items = new List<BoardCard>();
      for (Work_Item__c item : items) {
        board.items.add(toCard(item));
      }
      board.epics = new List<BoardEpic>();
      for (EpicRollup.Epic epic : new EpicRollup(items).epics()) {
        board.epics.add(toEpic(epic));
      }
      board.itemCount = items.size();
      board.projectId = projectId;
      board.projectLabel = ProjectSelector.labelFor(project);
      board.lastSyncedAt = mostRecentSync(items);
      board.canOpenRecord = canOpenRecord();
      board.titleMaxLength = TITLE_MAX;
      return board;
    } catch (Exception e) {
      // A raw exception reaches the client as an opaque server error. Converting it gives
      // the component something it can actually render in its error state.
      throw new AuraHandledException(
        'Could not load the board: ' + e.getMessage()
      );
    }
  }

  private static BoardCard toCard(Work_Item__c item) {
    BoardCard card = new BoardCard();
    card.id = item.Id;
    card.recordNumber = item.Name;
    card.title = item.Title__c;
    card.externalKey = item.External_Key__c;
    card.status = item.Status__c;
    card.type = item.Type__c == WorkItemType.UNSPECIFIED ? null : item.Type__c;
    card.projectLabel = item.Project__r == null
      ? null
      : (String.isNotBlank(item.Project__r.Short_Name__c)
          ? item.Project__r.Short_Name__c
          : item.Project__r.Name);
    card.parentId = item.Parent_Work_Item__c;
    // A record with no remote record will never push, so it has no sync state to show - not a
    // permanent Pending, which is what the seed canary WI-0011 displayed from build 06 to 08.
    card.syncStatus = String.isBlank(item.External_Id__c)
      ? null
      : item.Sync_Status__c;
    card.syncError = card.syncStatus == null ? null : item.Sync_Error__c;
    card.description = item.Description__c;
    card.storyPoints = item.Story_Points__c;

    BoardSourceRules.Source rules = BoardSourceRules.forSystem(
      item.External_System__c
    );
    card.sourceLabel = rules.label;
    card.accentToken = rules.accentToken;
    card.condensesIntoEpic = rules.condensesIntoEpics;
    card.supportsStartDate = rules.supportsStartDate;

    card.createdAt = item.Source_Created__c;
    card.startDate = IsoDate.format(item.Start_Date__c);
    card.dueDate = IsoDate.format(item.Due_Date__c);
    return card;
  }

  private static BoardEpic toEpic(EpicRollup.Epic source) {
    BoardEpic epic = new BoardEpic();
    epic.id = source.record.Id;
    epic.recordNumber = source.record.Name;
    epic.title = source.record.Title__c;
    epic.status = source.record.Status__c;
    epic.totalChildren = source.totalChildren;
    epic.completedChildren = source.completedChildren;
    BoardSourceRules.Source rules = BoardSourceRules.forSystem(
      source.record.External_System__c
    );
    epic.sourceLabel = rules.label;
    epic.accentToken = rules.accentToken;
    return epic;
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
   * the source system is not yet.
   *
   * @param workItemId the record to move
   * @param newStatus  a Status__c value; never Unspecified, which means "no mapping"
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
    if (newStatus == WorkItemStatus.UNSPECIFIED) {
      throw new AuraHandledException(
        'Unspecified means the source system reported a status we cannot map, so it cannot ' +
        'be chosen here.'
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
      result.message = savedMessage(saved, result.pushQueued);
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
   * Save title, start date and due date from the expanded card.
   *
   * Writes the fields that actually changed and nothing else, in USER_MODE, and leaves the push
   * to WorkItemTrigger exactly as changeStatus does: the trigger records the changed fields and
   * enqueues one push, so calling WorkItemSyncService here would either throw - a callout after
   * this DML - or push twice. The record reads Pending until the source confirms; nothing here
   * claims the source has changed.
   *
   * Validation is here, not only in the component, and the component mirrors it: a title is
   * required and at most TITLE_MAX characters, the start date is on or before the due date, and
   * a start date is refused for a source that cannot hold one - the trigger refuses that too, for
   * every other way a record can be edited. Validation problems come back per field, worded to
   * say how to fix them, rather than as an exception; only something unexpected throws.
   *
   * Dates travel as YYYY-MM-DD strings, never as a Date the browser built: new Date('YYYY-MM-DD')
   * is UTC midnight, which is the previous day west of Greenwich.
   *
   * @param workItemId the record to save
   * @param title      the title as typed; trimmed
   * @param startDate  YYYY-MM-DD, or blank for none
   * @param dueDate    YYYY-MM-DD, or blank for none
   */
  @AuraEnabled
  public static DetailSaveResult saveDetails(
    Id workItemId,
    String title,
    String startDate,
    String dueDate
  ) {
    if (workItemId == null) {
      throw new AuraHandledException('No work item was supplied.');
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
      BoardSourceRules.Source source = BoardSourceRules.forSystem(
        current.External_System__c
      );

      DetailSaveResult result = new DetailSaveResult();
      result.workItemId = workItemId;
      result.fieldErrors = new Map<String, String>();

      String cleanTitle = title == null ? '' : title.trim();
      if (cleanTitle.length() == 0) {
        result.fieldErrors.put(
          'title',
          'A title is required. Type one before saving.'
        );
      } else if (cleanTitle.length() > TITLE_MAX) {
        result.fieldErrors.put(
          'title',
          'The title is ' +
            cleanTitle.length() +
            ' characters; the limit is ' +
            TITLE_MAX +
            '. Shorten it by ' +
            (cleanTitle.length() - TITLE_MAX) +
            '.'
        );
      }

      Date start = readDay(startDate, 'startDate', 'start', result);
      Date due = readDay(dueDate, 'dueDate', 'due', result);
      if (start != null && !source.supportsStartDate) {
        result.fieldErrors.put(
          'startDate',
          (String.isBlank(source.label) ? 'This source' : source.label) +
          ' does not support start dates. Clear the start date to save.'
        );
      }
      if (
        start != null &&
        due != null &&
        start > due &&
        !result.fieldErrors.containsKey('startDate')
      ) {
        result.fieldErrors.put(
          'startDate',
          'The start date (' +
            IsoDate.format(start) +
            ') is after the due date (' +
            IsoDate.format(due) +
            '). Move one of them.'
        );
      }

      if (!result.fieldErrors.isEmpty()) {
        result.saved = false;
        result.syncStatus = current.Sync_Status__c;
        result.message = 'Nothing was saved. Fix the fields marked below.';
        return result;
      }

      // Only what changed, so a save touching the title alone needs no permission on the dates
      // and pushes nothing but the title. Title compared case-sensitively, because Apex's ==
      // on strings is not and a change of case is a real edit.
      Work_Item__c patch = new Work_Item__c(Id = workItemId);
      Boolean anyChange = false;
      if (!SyncFields.sameText(cleanTitle, current.Title__c)) {
        patch.Title__c = cleanTitle;
        anyChange = true;
      }
      if (start != current.Start_Date__c) {
        patch.Start_Date__c = start;
        anyChange = true;
      }
      if (due != current.Due_Date__c) {
        patch.Due_Date__c = due;
        anyChange = true;
      }
      if (!anyChange) {
        result.saved = false;
        result.pushQueued = false;
        result.syncStatus = current.Sync_Status__c;
        result.message = 'Nothing changed, so nothing was saved.';
        return result;
      }

      // Counting queued jobs across the DML is direct evidence that the trigger fired.
      Integer jobsBefore = Limits.getQueueableJobs();
      Database.update(patch, AccessLevel.USER_MODE);
      result.pushQueued = Limits.getQueueableJobs() > jobsBefore;

      Work_Item__c saved = WorkItemSelector.byIds(new Set<Id>{ workItemId })[0];
      result.saved = true;
      result.syncStatus = saved.Sync_Status__c;
      result.message = savedMessage(saved, result.pushQueued);
      return result;
    } catch (AuraHandledException e) {
      throw e;
    } catch (DmlException e) {
      // The trigger's start date rule, a validation rule, or a missing field permission. Its
      // own message is the useful part; the exception wrapper is not.
      throw new AuraHandledException('Could not save: ' + e.getDmlMessage(0));
    } catch (Exception e) {
      throw new AuraHandledException('Could not save: ' + e.getMessage());
    }
  }

  /**
   * Whether the running user sees the Open record link. A custom permission rather than a
   * profile check, so it is granted by assignment and an administrator without the permission
   * set does not get it by default. It gates a link, not access: the record page applies the
   * user's own sharing and permissions.
   */
  @TestVisible
  private static Boolean canOpenRecord() {
    return FeatureManagement.checkPermission(OPEN_RECORD_PERMISSION);
  }

  /** The stored title limit, capped at 255 - the most either source takes as a title. */
  @TestVisible
  private static final Integer TITLE_MAX = Math.min(
    Work_Item__c.Title__c.getDescribe().getLength(),
    255
  );

  private static Date readDay(
    String value,
    String fieldKey,
    String word,
    DetailSaveResult result
  ) {
    try {
      return IsoDate.parseDay(value);
    } catch (IsoDate.UnreadableDateException e) {
      result.fieldErrors.put(
        fieldKey,
        'The ' +
          word +
          ' date is not a date. Pick one from the calendar, or clear it.'
      );
      return null;
    }
  }

  /**
   * What a save means, in words that name the source by its label and never claim the source
   * has changed: the push is asynchronous, and the record says Pending until it confirms.
   */
  private static String savedMessage(Work_Item__c saved, Boolean pushQueued) {
    String label = BoardSourceRules.forSystem(saved.External_System__c).label;
    String sourceName = String.isBlank(label) ? 'source system' : label;
    if (pushQueued) {
      return 'Saved in Salesforce. The ' +
        sourceName +
        ' update is running in the background.';
    }
    if (String.isBlank(saved.External_Id__c)) {
      return 'Saved in Salesforce. This item has no ' +
        sourceName +
        ' record, so nothing is pushed.';
    }
    return 'Saved in Salesforce. No ' +
      sourceName +
      ' push was queued for this record.';
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
    public List<BoardCard> items { get; set; }
    /** The epic view, from EpicRollup - the same rules and code as the public board's. */
    @AuraEnabled
    public List<BoardEpic> epics { get; set; }
    @AuraEnabled
    public Integer itemCount { get; set; }
    @AuraEnabled
    public Id projectId { get; set; }
    /** Short_Name__c where set, Name otherwise. Null when the board is not project-scoped. */
    @AuraEnabled
    public String projectLabel { get; set; }
    @AuraEnabled
    public Datetime lastSyncedAt { get; set; }
    /** Whether the running user has Portfolio_HQ_Open_Record: the card's Open record link. */
    @AuraEnabled
    public Boolean canOpenRecord { get; set; }
    /** The title limit saveDetails enforces, so the card can say so before it sends. */
    @AuraEnabled
    public Integer titleMaxLength { get; set; }
  }

  /**
   * One card on the internal board. The first block of properties matches PublicCard name for
   * name, so both boards run the same client code over them; the second block is internal only.
   */
  public class BoardCard {
    @AuraEnabled
    public String recordNumber { get; set; }
    @AuraEnabled
    public String title { get; set; }
    @AuraEnabled
    public String externalKey { get; set; }
    @AuraEnabled
    public String status { get; set; }
    /** Null when the source's type has no mapping, as on the public board. */
    @AuraEnabled
    public String type { get; set; }
    @AuraEnabled
    public String projectLabel { get; set; }
    /** Null when the record has no remote record: it will never push. */
    @AuraEnabled
    public String syncStatus { get; set; }
    @AuraEnabled
    public Boolean condensesIntoEpic { get; set; }
    @AuraEnabled
    public String sourceLabel { get; set; }
    @AuraEnabled
    public String accentToken { get; set; }
    @AuraEnabled
    public Datetime createdAt { get; set; }
    /** YYYY-MM-DD, or null. */
    @AuraEnabled
    public String startDate { get; set; }
    /** YYYY-MM-DD, or null. */
    @AuraEnabled
    public String dueDate { get; set; }

    // Internal only.
    @AuraEnabled
    public Id id { get; set; }
    @AuraEnabled
    public Id parentId { get; set; }
    @AuraEnabled
    public String description { get; set; }
    @AuraEnabled
    public Decimal storyPoints { get; set; }
    /** Why the last push failed, when it did. */
    @AuraEnabled
    public String syncError { get; set; }
    /** Whether the card offers a start date editor. Apex refuses one either way. */
    @AuraEnabled
    public Boolean supportsStartDate { get; set; }
  }

  /** One epic on the internal board's Epics view: PublicEpic's fields, plus its id and number. */
  public class BoardEpic {
    @AuraEnabled
    public Id id { get; set; }
    @AuraEnabled
    public String recordNumber { get; set; }
    @AuraEnabled
    public String title { get; set; }
    @AuraEnabled
    public String status { get; set; }
    @AuraEnabled
    public Integer totalChildren { get; set; }
    @AuraEnabled
    public Integer completedChildren { get; set; }
    @AuraEnabled
    public String sourceLabel { get; set; }
    @AuraEnabled
    public String accentToken { get; set; }
  }

  /**
   * What saveDetails returns. fieldErrors is keyed by the component's field names - title,
   * startDate, dueDate - so each message can sit beside the input it is about. Empty when the
   * save went through.
   */
  public class DetailSaveResult {
    @AuraEnabled
    public Id workItemId { get; set; }
    @AuraEnabled
    public Boolean saved { get; set; }
    @AuraEnabled
    public Boolean pushQueued { get; set; }
    @AuraEnabled
    public String syncStatus { get; set; }
    @AuraEnabled
    public String message { get; set; }
    @AuraEnabled
    public Map<String, String> fieldErrors { get; set; }
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
