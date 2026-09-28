/**
 * BoardSourceRules answers every per-source question from Board_Source__mdt, and gives a source
 * with no record the answers that can never hide a card.
 *
 * Most tests inject their own table, because custom metadata cannot be inserted and a test that
 * read the deployed records would be measuring configuration rather than code. Two tests read the
 * deployed records on purpose: one to prove the read costs no SOQL, one to pin what the committed
 * records say - PublicBoardControllerTest relies on Jira condensing and Asana not, and if somebody
 * changes a record this is the test that names the cause.
 */
@IsTest
private class BoardSourceRulesTest {
  private static Board_Source__mdt row(
    String sourceSystem,
    String label,
    String token,
    Boolean supportsStart,
    Boolean condenses
  ) {
    return new Board_Source__mdt(
      External_System__c = sourceSystem,
      Display_Label__c = label,
      Accent_Token__c = token,
      Supports_Start_Date__c = supportsStart,
      Condenses_Into_Epics__c = condenses
    );
  }

  private static void inject(List<Board_Source__mdt> rows) {
    BoardSourceRules.reset();
    BoardSourceRules.injected = rows;
  }

  @IsTest
  static void answersEveryQuestionFromTheMetadata() {
    inject(
      new List<Board_Source__mdt>{
        row('Jira', 'Jira Cloud', 'accent-7', true, true),
        row('Asana', 'Asana', 'accent-2', false, false)
      }
    );

    BoardSourceRules.Source jira = BoardSourceRules.forSystem('Jira');
    Assert.areEqual(
      'Jira Cloud',
      jira.label,
      'The label is the record\'s, not the picklist value.'
    );
    Assert.areEqual('accent-7', jira.accentToken);
    Assert.isTrue(jira.supportsStartDate);
    Assert.isTrue(jira.condensesIntoEpics);

    Assert.isTrue(BoardSourceRules.condensesIntoEpics('Jira'));
    Assert.isTrue(BoardSourceRules.supportsStartDate('Jira'));
    Assert.isFalse(
      BoardSourceRules.condensesIntoEpics('Asana'),
      'Condensing is read from the record now, not from a hardcoded set of namespaces.'
    );
    Assert.isFalse(BoardSourceRules.supportsStartDate('Asana'));
  }

  @IsTest
  static void priorityIsReadFromTheRecordAndDefaultsToNo() {
    Board_Source__mdt jira = row('Jira', 'Jira', 'accent-1', true, true);
    jira.Supports_Priority__c = true;
    // Asana's row leaves the checkbox unset, which is how a record created before build 09 - or
    // by somebody who forgot the box - reads: no.
    inject(
      new List<Board_Source__mdt>{
        jira,
        row('Asana', 'Asana', 'accent-2', false, false)
      }
    );

    Assert.isTrue(BoardSourceRules.forSystem('Jira').supportsPriority);
    Assert.isTrue(BoardSourceRules.supportsPriority('Jira'));
    Assert.isFalse(
      BoardSourceRules.supportsPriority('Asana'),
      'The editor is offered on the record\'s word, and an unset box is not a yes.'
    );
  }

  @IsTest
  static void aRecordIsFoundWhateverTheCaseOrSpacing() {
    inject(
      new List<Board_Source__mdt>{ row('Jira', 'Jira', 'accent-1', true, true) }
    );

    Assert.areEqual(
      'accent-1',
      BoardSourceRules.forSystem(' jira ').accentToken
    );
    Assert.areEqual('accent-1', BoardSourceRules.forSystem('JIRA').accentToken);
  }

  @IsTest
  static void aSourceWithNoRecordGetsTheSafeAnswers() {
    inject(
      new List<Board_Source__mdt>{ row('Jira', 'Jira', 'accent-1', true, true) }
    );

    BoardSourceRules.Source unknown = BoardSourceRules.forSystem('Trello');
    Assert.areEqual(
      'Trello',
      unknown.label,
      'With no record the picklist value is the only name there is.'
    );
    Assert.isNull(unknown.accentToken, 'No token renders neutral.');
    Assert.isFalse(
      unknown.supportsStartDate,
      'A new source never inherits a capability by accident.'
    );
    Assert.isFalse(unknown.supportsPriority, 'Priority included.');
    Assert.isFalse(
      unknown.condensesIntoEpics,
      'Flat is never wrong: a card that does not condense is shown as itself.'
    );
  }

  @IsTest
  static void noSourceAtAllIsNotAnError() {
    inject(new List<Board_Source__mdt>());

    BoardSourceRules.Source none = BoardSourceRules.forSystem(null);
    Assert.areEqual('', none.label);
    Assert.isFalse(none.supportsStartDate);
    Assert.isFalse(none.supportsPriority);
    Assert.isFalse(BoardSourceRules.condensesIntoEpics(''));
  }

  @IsTest
  static void aBlankLabelFallsBackToTheSystemAndABlankTokenToNeutral() {
    inject(
      new List<Board_Source__mdt>{ row('Asana', '  ', ' ', false, false) }
    );

    BoardSourceRules.Source asana = BoardSourceRules.forSystem('Asana');
    Assert.areEqual('Asana', asana.label);
    Assert.isNull(asana.accentToken);
  }

  @IsTest
  static void readingTheDeployedRecordsCostsNoQuery() {
    BoardSourceRules.reset();
    BoardSourceRules.injected = null;

    Integer before = Limits.getQueries();
    BoardSourceRules.forSystem('Jira');
    BoardSourceRules.forSystem('Asana');
    Integer used = Limits.getQueries() - before;

    // The public board is held to one SOQL query per anonymous request and asks this class a
    // question for every card. getAll() is what keeps that true.
    Assert.areEqual(0, used, 'Board_Source__mdt must be read without SOQL.');
  }

  @IsTest
  static void theCommittedRecordsSayWhatTheBoardsExpect() {
    BoardSourceRules.reset();
    BoardSourceRules.injected = null;

    BoardSourceRules.Source jira = BoardSourceRules.forSystem('Jira');
    Assert.areEqual('Jira', jira.label);
    Assert.areEqual('accent-1', jira.accentToken);
    Assert.isTrue(jira.supportsStartDate, 'Jira has a start date field.');
    Assert.isTrue(jira.supportsPriority, 'Jira priority syncs (build 09).');
    Assert.isTrue(jira.condensesIntoEpics, 'Jira work rolls up into epics.');

    BoardSourceRules.Source asana = BoardSourceRules.forSystem('Asana');
    Assert.areEqual('Asana', asana.label);
    Assert.areEqual('accent-2', asana.accentToken);
    Assert.isFalse(
      asana.supportsStartDate,
      'Start dates are a paid Asana feature this workspace does not have.'
    );
    Assert.isTrue(
      asana.supportsPriority,
      'Asana priority syncs through the project\'s Priority field (build 09).'
    );
    Assert.isFalse(asana.condensesIntoEpics, 'Asana work is flat.');
  }

  @IsTest
  static void thePicklistNamesExactlyTheSystemsTheOrgKnows() {
    Set<String> inMetadata = new Set<String>();
    for (
      Schema.PicklistEntry entry : Board_Source__mdt.External_System__c.getDescribe()
        .getPicklistValues()
    ) {
      inMetadata.add(entry.getValue());
    }

    Assert.areEqual(
      new Set<String>{ ExternalSystem.JIRA, ExternalSystem.ASANA },
      inMetadata,
      'Custom metadata cannot use the External_System global value set, so this picklist is ' +
      'kept in step with ExternalSystem.cls by hand.'
    );
  }
}
