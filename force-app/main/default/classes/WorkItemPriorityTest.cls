/**
 * The priority order both boards sort by, read from the deployed picklist.
 */
@IsTest
private class WorkItemPriorityTest {
  @IsTest
  static void ranksFollowThePicklistOrder() {
    List<String> values = new List<String>();
    for (
      Schema.PicklistEntry entry : Work_Item__c.Priority__c.getDescribe()
        .getPicklistValues()
    ) {
      values.add(entry.getValue());
    }

    for (Integer i = 0; i < values.size(); i++) {
      Assert.areEqual(
        i + 1,
        WorkItemPriority.rankOf(values[i]),
        'Rank ' +
          (i + 1) +
          ' is the picklist\'s value number ' +
          (i + 1) +
          ': ' +
          values[i]
      );
      Assert.areEqual(values[i], WorkItemPriority.labelOf(values[i]));
    }
    Assert.areEqual(
      new List<Integer>{ 1, 2, 3 },
      new List<Integer>{
        WorkItemPriority.rankOf('High'),
        WorkItemPriority.rankOf('Medium'),
        WorkItemPriority.rankOf('Low')
      },
      'High first, Low last (decision 6).'
    );
  }

  @IsTest
  static void blankAndUnknownHaveNoRankAndNoLabel() {
    Assert.isNull(WorkItemPriority.rankOf(null));
    Assert.isNull(WorkItemPriority.rankOf(''));
    Assert.isNull(WorkItemPriority.rankOf('Urgent'));
    Assert.isNull(WorkItemPriority.labelOf(null));
    Assert.isNull(WorkItemPriority.labelOf('Urgent'));
    Assert.areEqual(
      1,
      WorkItemPriority.rankOf('high'),
      'Whatever case the value arrives in.'
    );
  }
}
