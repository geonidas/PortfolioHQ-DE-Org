/**
 * The mapping table, read in both directions.
 *
 * Records are custom metadata and cannot be created by DML, so every behavioural test injects.
 * The structural test does not: it reads the deployed picklist, because the one thing injection
 * cannot catch is the metadata type drifting away from the vocabulary the code compares against.
 */
@IsTest
private class FieldMappingServiceTest {
  private static void inject(List<Field_Mapping__mdt> rows) {
    FieldMappingService.reset();
    FieldMappingService.injected = rows;
  }

  @IsTest
  static void anExternalValueResolvesToItsNormalizedValue() {
    inject(AsanaPayloadFactory.statusMappings());

    Test.startTest();
    String mapped = FieldMappingService.normalizedFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      AsanaPayloadFactory.SECTION_IN_PROGRESS
    );
    Test.stopTest();

    Assert.areEqual(WorkItemStatus.IN_PROGRESS, mapped);
  }

  @IsTest
  static void theSameRowsReadBackwardsForAnOutboundPush() {
    inject(AsanaPayloadFactory.statusMappings());

    Test.startTest();
    String sectionGid = FieldMappingService.externalValueFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      WorkItemStatus.DONE
    );
    Test.stopTest();

    Assert.areEqual(
      AsanaPayloadFactory.SECTION_COMPLETED,
      sectionGid,
      'One table read both ways. Two tables drift, and drift here means inbound and outbound ' +
      'disagree about what a status means - which shows up as a task that moves and moves back.'
    );
  }

  @IsTest
  static void anAmbiguousReverseMappingResolvesToNothing() {
    // Two sections can legitimately both mean Done on the way in. Choosing one of them to push
    // to would be a guess that silently moves work to the wrong column.
    List<Field_Mapping__mdt> rows = AsanaPayloadFactory.statusMappings();
    rows.add(
      AsanaPayloadFactory.mapping(
        FieldMappingService.STATUS,
        '1209955555555555',
        'Also done',
        WorkItemStatus.DONE
      )
    );
    inject(rows);

    Test.startTest();
    String forward = FieldMappingService.normalizedFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      '1209955555555555'
    );
    String reverse = FieldMappingService.externalValueFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      WorkItemStatus.DONE
    );
    Test.stopTest();

    Assert.areEqual(
      WorkItemStatus.DONE,
      forward,
      'Both sections still mean Done on the way in.'
    );
    Assert.isNull(
      reverse,
      'But there is no single answer on the way out, so there is no answer at all.'
    );
  }

  @IsTest
  static void lookupsAreCaseAndWhitespaceTolerant() {
    inject(AsanaPayloadFactory.statusMappings());

    Test.startTest();
    String padded = FieldMappingService.normalizedFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      '  ' + AsanaPayloadFactory.SECTION_UP_NEXT + '  '
    );
    String cased = FieldMappingService.normalizedFor(
      'asana',
      'status',
      AsanaPayloadFactory.SECTION_UP_NEXT
    );
    Test.stopTest();

    Assert.areEqual(
      WorkItemStatus.TO_DO,
      padded,
      'A gid pasted with a stray space still matches.'
    );
    Assert.areEqual(
      WorkItemStatus.TO_DO,
      cased,
      'And the system and kind are matched however they are spelled.'
    );
  }

  @IsTest
  static void anInactiveOrIncompleteRowIsIgnored() {
    Field_Mapping__mdt retired = AsanaPayloadFactory.mapping(
      FieldMappingService.STATUS,
      '1209966666666666',
      'Retired',
      WorkItemStatus.TO_DO
    );
    retired.Is_Active__c = false;
    Field_Mapping__mdt halfFilled = AsanaPayloadFactory.mapping(
      FieldMappingService.STATUS,
      '1209977777777777',
      'Half filled',
      null
    );
    inject(new List<Field_Mapping__mdt>{ retired, halfFilled });

    Test.startTest();
    String fromRetired = FieldMappingService.normalizedFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      '1209966666666666'
    );
    String fromHalfFilled = FieldMappingService.normalizedFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      '1209977777777777'
    );
    Test.stopTest();

    Assert.isNull(
      fromRetired,
      'Retiring a mapping keeps the row so an old log line still explains itself, and stops ' +
      'it being used.'
    );
    Assert.isNull(
      fromHalfFilled,
      'And a row with no normalized value maps nothing.'
    );
  }

  @IsTest
  static void mappingsAreScopedToTheirSystem() {
    inject(AsanaPayloadFactory.statusMappings());

    Test.startTest();
    String wrongSystem = FieldMappingService.normalizedFor(
      ExternalSystem.JIRA,
      FieldMappingService.STATUS,
      AsanaPayloadFactory.SECTION_IN_PROGRESS
    );
    String wrongKind = FieldMappingService.normalizedFor(
      ExternalSystem.ASANA,
      FieldMappingService.TYPE,
      AsanaPayloadFactory.SECTION_IN_PROGRESS
    );
    Test.stopTest();

    Assert.isNull(wrongSystem, 'An Asana section gid means nothing to Jira.');
    Assert.isNull(wrongKind, 'And nothing as a type either.');
  }

  @IsTest
  static void anUnknownValueMapsToNothingRatherThanAFallback() {
    inject(AsanaPayloadFactory.statusMappings());

    Test.startTest();
    String unknown = FieldMappingService.normalizedFor(
      ExternalSystem.ASANA,
      FieldMappingService.STATUS,
      'not-a-section'
    );
    Test.stopTest();

    Assert.isNull(
      unknown,
      'Null, not Unspecified. What an unmapped value should become differs by field, and that ' +
      'is a decision for the caller filling it.'
    );
  }

  @IsTest
  static void theMetadataPicklistMatchesTheSystemsTheCodeKnows() {
    // Custom metadata types cannot use a global value set - the deploy says "Global picklists
    // are not supported on this object" - so External_System__c here is a local copy of the
    // External_System global set. A copy drifts unless something compares it.
    Set<String> inMetadata = new Set<String>();
    for (
      Schema.PicklistEntry entry : Field_Mapping__mdt.External_System__c.getDescribe()
        .getPicklistValues()
    ) {
      inMetadata.add(entry.getValue());
    }

    Assert.areEqual(
      new Set<String>{ ExternalSystem.JIRA, ExternalSystem.ASANA },
      inMetadata,
      'The mapping table can name a system no adapter answers for, or fail to name one that ' +
      'exists. Keep this picklist and ExternalSystem.cls in step by hand.'
    );
  }
}
