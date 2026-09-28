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

  // ---------- the featured epic (build 10) ----------

  /** A row as loaded, last modified the given number of minutes ago. EpicRollup reads rows in
   * memory, so its Done-epic ordering can be tested without waiting for the clock. */
  private static Work_Item__c aged(Work_Item__c row, Integer minutesAgo) {
    Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(
      JSON.serialize(row)
    );
    fields.put('LastModifiedDate', Datetime.now().addMinutes(-minutesAgo));
    return (Work_Item__c) JSON.deserialize(
      JSON.serialize(fields),
      Work_Item__c.class
    );
  }

  private static Set<Id> listedIds(List<EpicRollup.Epic> epics) {
    Set<Id> ids = new Set<Id>();
    for (EpicRollup.Epic epic : epics) {
      ids.add(epic.record.Id);
    }
    return ids;
  }

  /**
   * The owner's answer to step 0's question 3: a featured epic moved to Done keeps its card
   * however many finished epics are newer. The others are capped exactly as before.
   */
  @IsTest
  static void aFeaturedDoneEpicKeepsItsCardPastTheCap() {
    List<Work_Item__c> rows = new List<Work_Item__c>();
    for (Integer i = 0; i < 5; i++) {
      rows.add(row('Epic', 'Done', null));
    }
    List<Work_Item__c> loaded = new List<Work_Item__c>();
    Map<Id, Work_Item__c> byId = new Map<Id, Work_Item__c>(reread());
    for (Integer i = 0; i < rows.size(); i++) {
      // rows[0] is the newest, rows[4] the oldest.
      loaded.add(aged(byId.get(rows[i].Id), i + 1));
    }
    Id oldest = rows[4].Id;

    List<EpicRollup.Epic> unfeatured = new EpicRollup(loaded).epics();
    List<EpicRollup.Epic> featured = new EpicRollup(loaded, oldest).epics();

    Assert.areEqual(
      new Set<Id>{ rows[0].Id, rows[1].Id, rows[2].Id },
      listedIds(unfeatured),
      'Unfeatured, the three most recent, as before build 10.'
    );
    Assert.areEqual(
      new Set<Id>{ rows[0].Id, rows[1].Id, rows[2].Id, oldest },
      listedIds(featured),
      'Featured, the oldest is listed as well, and the three most recent are untouched.'
    );
    for (EpicRollup.Epic epic : featured) {
      Assert.areEqual(epic.record.Id == oldest, epic.isFeatured);
    }
    for (EpicRollup.Epic epic : unfeatured) {
      Assert.isFalse(epic.isFeatured);
    }
  }

  @IsTest
  static void workUnderTheFeaturedEpicStaysAfterItIsDone() {
    Work_Item__c featuredEpic = row('Epic', 'Done', null);
    Work_Item__c otherEpic = row('Epic', 'Done', null);
    Work_Item__c underFeatured = row('Story', 'Done', featuredEpic.Id);
    Work_Item__c underOther = row('Story', 'To Do', otherEpic.Id);
    Map<Id, Work_Item__c> byId = new Map<Id, Work_Item__c>(reread());

    EpicRollup rollup = new EpicRollup(byId.values(), featuredEpic.Id);

    Assert.isTrue(
      rollup.keptInPublicTaskView(byId.get(underFeatured.Id)),
      'The featured epic\'s work stays while it is featured, Done or not.'
    );
    Assert.isFalse(
      rollup.keptInPublicTaskView(byId.get(underOther.Id)),
      'Every other finished epic\'s work leaves as before.'
    );
    Assert.isFalse(
      new EpicRollup(byId.values())
        .keptInPublicTaskView(byId.get(underFeatured.Id)),
      'And once it is no longer featured, so does its own.'
    );
  }

  /** Membership as the card counts it: a grandchild is in, another epic's child is not. */
  @IsTest
  static void membershipOfTheFeaturedEpicIsAsItsCardCountsIt() {
    Work_Item__c featuredEpic = row('Epic', 'In Progress', null);
    Work_Item__c otherEpic = row('Epic', 'In Progress', null);
    Work_Item__c child = row('Story', 'To Do', featuredEpic.Id);
    Work_Item__c grandchild = row('Task', 'To Do', child.Id);
    Work_Item__c otherChild = row('Story', 'To Do', otherEpic.Id);
    Work_Item__c orphan = row('Story', 'To Do', null);

    EpicRollup rollup = new EpicRollup(reread(), featuredEpic.Id);

    Assert.isTrue(rollup.inFeaturedEpic(child.Id));
    Assert.isTrue(
      rollup.inFeaturedEpic(grandchild.Id),
      'Two hops down counts, as it does on the card.'
    );
    Assert.isFalse(rollup.inFeaturedEpic(otherChild.Id));
    Assert.isFalse(rollup.inFeaturedEpic(orphan.Id));
    Assert.isFalse(
      rollup.inFeaturedEpic(featuredEpic.Id),
      'An epic is not a member of itself.'
    );
    Assert.areEqual(2, rollup.epics()[0].totalChildren);
  }

  /** An Id the caller did not load, or that is not an epic, features nothing. */
  @IsTest
  static void anIdThatIsNotALoadedEpicFeaturesNothing() {
    Work_Item__c theEpic = row('Epic', 'In Progress', null);
    Work_Item__c story = row('Story', 'To Do', theEpic.Id);
    List<Work_Item__c> loaded = reread();

    for (Id candidate : new List<Id>{ story.Id, null }) {
      EpicRollup rollup = new EpicRollup(loaded, candidate);
      Assert.isFalse(rollup.inFeaturedEpic(story.Id));
      Assert.isFalse(rollup.epics()[0].isFeatured);
    }
    Work_Item__c notLoaded = row('Epic', 'In Progress', null);
    EpicRollup rollup = new EpicRollup(loaded, notLoaded.Id);
    Assert.isFalse(rollup.epics()[0].isFeatured);
    Assert.isFalse(rollup.inFeaturedEpic(story.Id));
  }
}
