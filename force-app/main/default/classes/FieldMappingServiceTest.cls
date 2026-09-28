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
    Assert.isFalse(
      FieldMappingService.isMapped(
        ExternalSystem.ASANA,
        FieldMappingService.STATUS,
        '1209977777777777'
      ),
      'Not even to blank: without Maps_To_Blank__c an empty value is a row somebody forgot to ' +
      'finish.'
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

  // ---------- priority (build 09) ----------

  private static Field_Mapping__mdt priorityRow(
    String sourceSystem,
    String externalValue,
    String normalized,
    Boolean mapsToBlank
  ) {
    return new Field_Mapping__mdt(
      External_System__c = sourceSystem,
      Mapping_Type__c = FieldMappingService.PRIORITY,
      External_Value__c = externalValue,
      External_Label__c = externalValue,
      Normalized_Value__c = normalized,
      Maps_To_Blank__c = mapsToBlank,
      Is_Active__c = true
    );
  }

  /** The shape of the deployed Jira rows: three values and the en dash, which means none. */
  private static List<Field_Mapping__mdt> jiraPriorities() {
    return new List<Field_Mapping__mdt>{
      priorityRow(ExternalSystem.JIRA, '2', 'High', false),
      priorityRow(ExternalSystem.JIRA, '3', 'Medium', false),
      priorityRow(ExternalSystem.JIRA, '4', 'Low', false),
      priorityRow(ExternalSystem.JIRA, '10000', null, true)
    };
  }

  @IsTest
  static void aPriorityIdResolvesInBothDirections() {
    inject(jiraPriorities());

    Test.startTest();
    String inbound = FieldMappingService.normalizedFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '2'
    );
    String outbound = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      'Low'
    );
    Test.stopTest();

    Assert.areEqual('High', inbound);
    Assert.areEqual('4', outbound, 'By id, never by name (decision 2).');
  }

  @IsTest
  static void theIdThatMeansNoPriorityIsMappedAndReadsAsBlank() {
    inject(jiraPriorities());

    Test.startTest();
    Boolean mapped = FieldMappingService.isMapped(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '10000'
    );
    String normalized = FieldMappingService.normalizedFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '10000'
    );
    Test.stopTest();

    Assert.isTrue(
      mapped,
      'The en dash is a known value. It must not read as unknown, which would leave a stale ' +
      'priority in place instead of clearing it.'
    );
    Assert.isNull(
      normalized,
      'And what it means is no priority: blank, not a sentinel (decision 1).'
    );
  }

  @IsTest
  static void aBlankPriorityPushesAsTheIdThatMeansNone() {
    inject(jiraPriorities());

    Test.startTest();
    String fromNull = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      null
    );
    String fromEmpty = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      ''
    );
    String fromSpaces = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '  '
    );
    Test.stopTest();

    Assert.areEqual(
      '10000',
      fromNull,
      'A cleared priority goes out as the en dash.'
    );
    Assert.areEqual('10000', fromEmpty);
    Assert.areEqual('10000', fromSpaces);
  }

  @IsTest
  static void anUnknownPriorityIsNotMappedAtAll() {
    inject(jiraPriorities());

    Test.startTest();
    // Highest: gone from DOPP's scheme, still on the Jira site.
    Boolean mapped = FieldMappingService.isMapped(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '1'
    );
    String normalized = FieldMappingService.normalizedFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '1'
    );
    Test.stopTest();

    Assert.isFalse(
      mapped,
      'Unknown and none both normalize to null; isMapped is what tells the adapter to leave the ' +
      'field alone rather than clear it (decision 4).'
    );
    Assert.isNull(normalized);
  }

  @IsTest
  static void aSourceWithNoBlankRowHasNoValueForBlank() {
    inject(
      new List<Field_Mapping__mdt>{
        priorityRow(ExternalSystem.ASANA, '1209900000000001', 'High', false),
        priorityRow(ExternalSystem.ASANA, '1209900000000002', 'Medium', false),
        priorityRow(ExternalSystem.ASANA, '1209900000000003', 'Low', false)
      }
    );

    Test.startTest();
    String forBlank = FieldMappingService.externalValueFor(
      ExternalSystem.ASANA,
      FieldMappingService.PRIORITY,
      null
    );
    String forMedium = FieldMappingService.externalValueFor(
      ExternalSystem.ASANA,
      FieldMappingService.PRIORITY,
      'Medium'
    );
    Test.stopTest();

    Assert.isNull(
      forBlank,
      'Asana has no option meaning none - an empty field is its none. Null here, and the ' +
      'adapter, which knows that, sends an empty value.'
    );
    Assert.areEqual('1209900000000002', forMedium);
  }

  @IsTest
  static void aRowThatBothMapsToBlankAndNamesAValueMapsNothing() {
    List<Field_Mapping__mdt> rows = new List<Field_Mapping__mdt>{
      priorityRow(ExternalSystem.JIRA, '10000', 'Low', true)
    };
    inject(rows);

    Test.startTest();
    Boolean mapped = FieldMappingService.isMapped(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '10000'
    );
    String forLow = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      'Low'
    );
    String forBlank = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      null
    );
    Test.stopTest();

    Assert.isFalse(
      mapped,
      'Blank or Low - the row cannot mean both, and guessing which half was meant would push ' +
      'the wrong one.'
    );
    Assert.isNull(forLow);
    Assert.isNull(forBlank);
  }

  @IsTest
  static void twoIdsThatMeanNoneReadAsBlankButGiveNothingToPush() {
    List<Field_Mapping__mdt> rows = jiraPriorities();
    rows.add(priorityRow(ExternalSystem.JIRA, '10001', null, true));
    inject(rows);

    Test.startTest();
    String inbound = FieldMappingService.normalizedFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '10001'
    );
    Boolean mapped = FieldMappingService.isMapped(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      '10001'
    );
    String outbound = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      null
    );
    Test.stopTest();

    Assert.isTrue(mapped, 'Both still mean none on the way in.');
    Assert.isNull(inbound);
    Assert.isNull(
      outbound,
      'The same ambiguity rule as statuses: two candidates on the way out is no answer.'
    );
  }

  @IsTest
  static void theDeployedPriorityRowsCoverEveryValueBothWays() {
    // Reads the committed records on purpose: injection proves the code, this proves the
    // configuration it runs against. Every value either source can hold must survive a round trip,
    // or a priority set on one side quietly never reaches the other.
    FieldMappingService.reset();
    FieldMappingService.injected = null;

    List<String> values = new List<String>();
    for (
      Schema.PicklistEntry entry : Work_Item__c.Priority__c.getDescribe()
        .getPicklistValues()
    ) {
      values.add(entry.getValue());
    }
    Assert.areEqual(
      new List<String>{ 'High', 'Medium', 'Low' },
      values,
      'Three values, in priority order: the boards sort by this order (decision 6).'
    );

    for (
      String sourceSystem : new List<String>{
        ExternalSystem.JIRA,
        ExternalSystem.ASANA
      }
    ) {
      Assert.isTrue(
        BoardSourceRules.supportsPriority(sourceSystem),
        sourceSystem + ' should say it supports priority.'
      );
      for (String value : values) {
        String external = FieldMappingService.externalValueFor(
          sourceSystem,
          FieldMappingService.PRIORITY,
          value
        );
        Assert.isNotNull(external, sourceSystem + ' has no id for ' + value);
        Assert.areEqual(
          value,
          FieldMappingService.normalizedFor(
            sourceSystem,
            FieldMappingService.PRIORITY,
            external
          ),
          sourceSystem + ' ' + external + ' does not read back as ' + value
        );
      }
    }

    String jiraNone = FieldMappingService.externalValueFor(
      ExternalSystem.JIRA,
      FieldMappingService.PRIORITY,
      null
    );
    Assert.isNotNull(jiraNone, 'Jira needs an id for no priority.');
    Assert.isTrue(
      FieldMappingService.isMapped(
        ExternalSystem.JIRA,
        FieldMappingService.PRIORITY,
        jiraNone
      )
    );
    Assert.isNull(
      FieldMappingService.normalizedFor(
        ExternalSystem.JIRA,
        FieldMappingService.PRIORITY,
        jiraNone
      ),
      'And it reads back as blank.'
    );
    Assert.isNull(
      FieldMappingService.externalValueFor(
        ExternalSystem.ASANA,
        FieldMappingService.PRIORITY,
        null
      ),
      'Asana has no row for none: an empty field is its none.'
    );
    Assert.isNotNull(
      FieldMappingService.externalValueFor(
        ExternalSystem.ASANA,
        FieldMappingService.FIELD,
        'Priority__c'
      ),
      'The adapter finds the Priority field by its gid, which is configuration.'
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
