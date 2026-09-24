/**
 * The one definition of "a pushable field changed", and the stored form of the set.
 */
@IsTest
private class SyncFieldsTest {
  private static Work_Item__c item(
    String status,
    String title,
    Date startDate,
    Date dueDate
  ) {
    return new Work_Item__c(
      External_Id__c = 'jira:10023',
      Status__c = status,
      Title__c = title,
      Start_Date__c = startDate,
      Due_Date__c = dueDate
    );
  }

  @IsTest
  static void eachPushableFieldIsItsOwnChange() {
    Work_Item__c prior = item('To Do', 'A', null, null);

    Assert.areEqual(
      new Set<SyncField>{ SyncField.STATUS },
      SyncFields.changedBetween(item('Done', 'A', null, null), prior)
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      SyncFields.changedBetween(item('To Do', 'B', null, null), prior)
    );
    Assert.areEqual(
      new Set<SyncField>{ SyncField.START_DATE, SyncField.DUE_DATE },
      SyncFields.changedBetween(
        item('To Do', 'A', Date.today(), Date.today()),
        prior
      )
    );
  }

  @IsTest
  static void aChangeOfCaseIsAChange() {
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      SyncFields.changedBetween(
        item('To Do', 'Deep Work', null, null),
        item('To Do', 'Deep work', null, null)
      ),
      'Apex == on strings ignores case; this must not.'
    );
    Assert.isTrue(SyncFields.sameText(null, null));
    Assert.isFalse(SyncFields.sameText('a', null));
    Assert.isFalse(SyncFields.sameText(null, 'a'));
  }

  @IsTest
  static void nothingIsPushableWithoutARemoteRecordOrToUnspecified() {
    Work_Item__c local = item('Done', 'B', null, null);
    local.External_Id__c = null;
    // Held in locals rather than chained: prettier splits a long static call chain so the class
    // name sits alone on a line, and the Apex compiler then reads it as a variable that does not
    // exist.
    Set<SyncField> fromLocal = SyncFields.changedBetween(
      local,
      item('To Do', 'A', null, null)
    );
    Set<SyncField> toUnspecified = SyncFields.changedBetween(
      item('Unspecified', 'A', null, null),
      item('To Do', 'A', null, null)
    );
    Set<SyncField> fromInsert = SyncFields.changedBetween(
      item('To Do', 'A', null, null),
      null
    );
    Assert.isTrue(
      fromLocal.isEmpty(),
      'No External_Id__c, no remote record to update.'
    );
    Assert.isTrue(
      toUnspecified.isEmpty(),
      'Unspecified means no mapping, so there is nothing to ask for.'
    );
    Assert.isTrue(fromInsert.isEmpty(), 'An insert is not a change.');
  }

  @IsTest
  static void theStoredFormRoundTripsInDeclarationOrder() {
    Set<SyncField> fields = new Set<SyncField>{
      SyncField.DUE_DATE,
      SyncField.STATUS
    };
    Assert.areEqual(
      'STATUS;DUE_DATE',
      SyncFields.serialize(fields),
      'Equal sets store equally, whatever order they were built in.'
    );
    Assert.areEqual(fields, SyncFields.parse('STATUS;DUE_DATE'));
    Assert.isNull(SyncFields.serialize(new Set<SyncField>()));
    Assert.isNull(SyncFields.serialize(null));
    Assert.isTrue(SyncFields.parse(null).isEmpty());
  }

  @IsTest
  static void anUnknownStoredNameIsDroppedNotFatal() {
    Assert.areEqual(
      new Set<SyncField>{ SyncField.TITLE },
      SyncFields.parse(' title ; RENAMED_FIELD ;'),
      'A name from a future or past version must not strand the record.'
    );
  }

  @IsTest
  static void describesTheFieldsInWords() {
    Assert.areEqual(
      'title',
      SyncFields.describe(new Set<SyncField>{ SyncField.TITLE })
    );
    Assert.areEqual(
      'status, title and due date',
      SyncFields.describe(
        new Set<SyncField>{
          SyncField.DUE_DATE,
          SyncField.TITLE,
          SyncField.STATUS
        }
      )
    );
    Assert.areEqual('nothing', SyncFields.describe(new Set<SyncField>()));
  }
}
