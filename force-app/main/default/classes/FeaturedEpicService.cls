/**
 * Which epic the public board features: reads, sets and clears it. Build 10.
 *
 * The featured epic is the org default of the Featured_Epic__c hierarchy custom setting, so there
 * is one by construction, and Epic_Id__c holds the epic's Id as text (ADR build-10, decision 1).
 * A setting rather than a field on Work_Item__c, so featuring an epic is never a work item edit:
 * WorkItemTrigger does not run, nothing is staged in Pending_Push_Fields__c, no push is queued and
 * no adapter is asked anything (decision 2). The only row this class writes is the setting's.
 *
 * What can be featured is one rule, used when setting and again when reading back: an epic as
 * EpicRollup defines one, that the public board can show - the epic and its project both public
 * (decision 3, as the owner's answer to step 0's question 4 amended it). An epic that stops meeting
 * it - deleted, retyped by a delivery, made private - is read as none, not cleared (decision 7):
 * its Id stays in the setting until the owner features another epic or clears it.
 *
 * Who may set it is not decided here. The internal board's controller checks
 * Portfolio_HQ_Feature_Epic before calling in; the scripts in scripts/apex are run by an admin.
 * Nothing public writes it.
 */
public with sharing class FeaturedEpicService {
  /** What a set or clear did, in words a board can show. */
  public class Result {
    /** True when the setting was written. False for a refusal and for "nothing to change". */
    @AuraEnabled
    public Boolean saved { get; private set; }
    @AuraEnabled
    public String message { get; private set; }

    private Result(Boolean saved, String message) {
      this.saved = saved;
      this.message = message;
    }
  }

  /**
   * The Id the setting holds, whether or not it still resolves. No query: a custom setting read
   * comes from the application cache, which is what lets the public board read it and stay at
   * one query. Blank, malformed, or the Id of anything but a work item reads as null.
   */
  public static Id storedId() {
    String value = Featured_Epic__c.getOrgDefaults().Epic_Id__c;
    if (String.isBlank(value)) {
      return null;
    }
    try {
      Id stored = Id.valueOf(value.trim());
      return stored.getSObjectType() == Work_Item__c.SObjectType
        ? stored
        : null;
    } catch (StringException e) {
      return null;
    }
  }

  /**
   * The featured epic, or null when none is set or the stored Id no longer resolves to one that
   * can be featured. One query, and only when something is stored. For scripts and checks: the
   * boards resolve against the rows they have already loaded, so the public board spends no
   * query on this.
   */
  public static Id read() {
    Id stored = storedId();
    if (stored == null) {
      return null;
    }
    Work_Item__c row = lookUp(new Set<Id>{ stored }).get(stored);
    return row != null && canBeFeatured(row) ? stored : null;
  }

  /**
   * Whether a row can be the featured epic. The row needs Name, Type__c, Is_Public__c, Project__c
   * and Project__r.Is_Public__c.
   */
  public static Boolean canBeFeatured(Work_Item__c row) {
    return whyNot(row) == null;
  }

  /**
   * Features an epic, replacing whichever was featured. Refused with a reason for anything that
   * cannot be featured, and then nothing is written and the featured epic stays as it was.
   *
   * The epic is read in the caller's mode, so a user cannot feature what they cannot see. The
   * setting is written in system mode: the custom permission the controller checks is what
   * authorises the write, and no user is granted the setting itself.
   */
  public static Result feature(Id epicId) {
    if (epicId == null) {
      return new Result(
        false,
        'No epic was supplied, so nothing was featured.'
      );
    }
    if (epicId.getSObjectType() != Work_Item__c.SObjectType) {
      return new Result(
        false,
        'That is not a work item, so it cannot be featured.'
      );
    }
    Id current = storedId();
    Map<Id, Work_Item__c> rows = lookUp(new Set<Id>{ epicId, current });
    Work_Item__c epic = rows.get(epicId);
    if (epic == null) {
      return new Result(
        false,
        'That work item is not available to you. It may have been deleted.'
      );
    }
    String reason = whyNot(epic);
    if (reason != null) {
      return new Result(false, reason);
    }
    if (epicId == current) {
      return new Result(
        false,
        epic.Name +
        ' is already featured on the public board. Nothing was changed.'
      );
    }

    Featured_Epic__c setting = Featured_Epic__c.getOrgDefaults();
    if (setting.Id == null) {
      setting.SetupOwnerId = UserInfo.getOrganizationId();
    }
    setting.Epic_Id__c = String.valueOf(epicId);
    upsert setting;

    Work_Item__c replaced = current == null ? null : rows.get(current);
    return new Result(
      true,
      epic.Name +
        ' is featured on the public board' +
        (replaced == null ? '' : ', in place of ' + replaced.Name) +
        '. Open public boards show it within about 30 seconds.'
    );
  }

  /** Features nothing. The public board then opens on its Epics view (decision 7). */
  public static Result clear() {
    Featured_Epic__c setting = Featured_Epic__c.getOrgDefaults();
    if (setting.Id == null || String.isBlank(setting.Epic_Id__c)) {
      return new Result(false, 'No epic is featured, so nothing was changed.');
    }
    Id current = storedId();
    Work_Item__c was = current == null
      ? null
      : lookUp(new Set<Id>{ current }).get(current);
    setting.Epic_Id__c = null;
    update setting;
    return new Result(
      true,
      (was == null ? 'The featured epic' : was.Name) +
      ' is no longer featured on the public board. Open public boards show that within about 30 seconds.'
    );
  }

  /**
   * Why a row cannot be featured, or null when it can: the one rule for set and read. Each reason
   * says what to change.
   */
  private static String whyNot(Work_Item__c row) {
    if (!EpicRollup.isEpic(row)) {
      // Unspecified means "no mapping", not a type, so the reason does not call it one.
      String named = row.Type__c == WorkItemType.UNSPECIFIED
        ? null
        : row.Type__c;
      return row.Name +
        ' is not an epic' +
        (String.isBlank(named) ? '' : ' (its type is ' + named + ')') +
        '. Only an epic can be featured on the public board.';
    }
    if (row.Is_Public__c != true) {
      return row.Name +
        ' is not public, so the public board cannot show it. Make it public, then feature it.';
    }
    if (row.Project__c == null) {
      return row.Name +
        ' belongs to no project, and the public board shows only work under a public project.';
    }
    if (row.Project__r.Is_Public__c != true) {
      return row.Name +
        '\'s project is not public, so the public board cannot show it. Make the project public, then feature it.';
    }
    return null;
  }

  private static Map<Id, Work_Item__c> lookUp(Set<Id> ids) {
    return new Map<Id, Work_Item__c>(
      [
        SELECT
          Id,
          Name,
          Type__c,
          Is_Public__c,
          Project__c,
          Project__r.Is_Public__c
        FROM Work_Item__c
        WHERE Id IN :ids
        WITH USER_MODE
      ]
    );
  }

  private FeaturedEpicService() {
  }
}
