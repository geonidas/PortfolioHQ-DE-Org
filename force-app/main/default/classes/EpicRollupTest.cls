/**
 * The epic rules directly. PublicBoardControllerTest covers them through the public payload;
 * these pin the three that are easiest to break without noticing.
 */
@IsTest
private class EpicRollupTest {
  private static Work_Item__c row(String type, String status, Id parentId) {
    Work_Item__c item = TestDataFactory.createWorkItems(1, null, false)[0];
    item.Type__c = type;
    item.Status__c = status;
    item.Parent_Work_Item__c = parentId;
    insert item;
    return item;
  }

  private static List<Work_Item__c> reread() {
    return [
      SELECT
        Id,
        Type__c,
        Status__c,
        Parent_Work_Item__c,
        External_System__c,
        LastModifiedDate
      FROM Work_Item__c
    ];
  }

  @IsTest
  static void aDescendantTwoHopsDownCountsTowardsItsEpic() {
    Work_Item__c epic = row('Epic', 'In Progress', null);
    Work_Item__c story = row('Story', 'Done', epic.Id);
    Work_Item__c subtask = row('Task', 'To Do', story.Id);

    EpicRollup rollup = new EpicRollup(reread());

    Assert.areEqual(epic.Id, rollup.epicOf(subtask.Id));
    Assert.areEqual(2, rollup.epics()[0].totalChildren);
    Assert.areEqual(1, rollup.epics()[0].completedChildren);
  }

  @IsTest
  static void aParentCycleEndsAsNoEpicRatherThanALoop() {
    Work_Item__c a = row('Story', 'To Do', null);
    Work_Item__c b = row('Story', 'To Do', a.Id);
    update new Work_Item__c(Id = a.Id, Parent_Work_Item__c = b.Id);

    EpicRollup rollup = new EpicRollup(reread());

    Assert.isNull(rollup.epicOf(a.Id));
    Assert.isNull(rollup.epicOf(b.Id));
  }

  @IsTest
  static void thePublicTaskViewDropsFinishedOrphansAndWorkUnderFinishedEpics() {
    Work_Item__c openEpic = row('Epic', 'In Progress', null);
    Work_Item__c doneEpic = row('Epic', 'Done', null);
    Work_Item__c underOpen = row('Story', 'Done', openEpic.Id);
    Work_Item__c underDone = row('Story', 'To Do', doneEpic.Id);
    Work_Item__c doneOrphan = row('Story', 'Done', null);
    Work_Item__c openOrphan = row('Story', 'To Do', null);

    EpicRollup rollup = new EpicRollup(reread());
    Map<Id, Work_Item__c> byId = new Map<Id, Work_Item__c>(reread());

    Assert.isTrue(rollup.keptInPublicTaskView(byId.get(underOpen.Id)));
    Assert.isFalse(rollup.keptInPublicTaskView(byId.get(underDone.Id)));
    Assert.isFalse(rollup.keptInPublicTaskView(byId.get(doneOrphan.Id)));
    Assert.isTrue(rollup.keptInPublicTaskView(byId.get(openOrphan.Id)));
    Assert.isFalse(
      rollup.keptInPublicTaskView(byId.get(openEpic.Id)),
      'An epic is not a task.'
    );
  }

  /**
   * Build 10: the one definition of an epic, which the featured epic is checked against as well
   * as the Epics view. A type, and nothing about status, source or visibility.
   */
  @IsTest
  static void anEpicIsARowTypedEpicAndNothingElse() {
    Assert.isTrue(EpicRollup.isEpic(new Work_Item__c(Type__c = 'Epic')));
    Assert.isTrue(
      EpicRollup.isEpic(new Work_Item__c(Type__c = 'Epic', Status__c = 'Done'))
    );
    Assert.isFalse(EpicRollup.isEpic(new Work_Item__c(Type__c = 'Story')));
    Assert.isFalse(
      EpicRollup.isEpic(new Work_Item__c(Type__c = 'Unspecified'))
    );
    Assert.isFalse(EpicRollup.isEpic(new Work_Item__c()));
    Assert.isFalse(EpicRollup.isEpic(null));
  }
}
