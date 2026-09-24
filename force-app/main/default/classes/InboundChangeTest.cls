/**
 * The vendor-neutral inbound DTO.
 *
 * Most of this class is covered incidentally by the adapter and processor suites. What is
 * asserted here is the one thing those cannot assert: that a field nothing populates yet stays
 * null, and that the optional-field contract - null means "the delivery did not carry it" - is
 * the default rather than something a caller has to arrange.
 */
@IsTest
private class InboundChangeTest {
  @IsTest
  static void aChangeCarriesNoIterationReferenceUnlessOneIsSet() {
    InboundChange change = new InboundChange();

    Assert.isNull(
      change.iterationRef,
      'A change nobody gave an iteration to must carry none. The processor reads every ' +
        'optional field as "null means not carried", so a non-null default here would ' +
        'later look like a delivery that named an iteration.'
    );
  }

  @IsTest
  static void anIterationReferenceCarriesAnIdAndAName() {
    InboundChange change = new InboundChange();
    change.iterationRef = new InboundChange.IterationRef('jira:42', 'Sprint 7');

    Assert.areEqual(
      'jira:42',
      change.iterationRef.externalId,
      'The identifier is namespaced, like every other external reference on this DTO.'
    );
    Assert.areEqual(
      'Sprint 7',
      change.iterationRef.name,
      'The display name is the vendor\'s own word for the iteration.'
    );
  }

  @IsTest
  static void aChangeIsUsableUntilSomethingFailsIt() {
    InboundChange change = new InboundChange();
    Assert.isTrue(change.isUsable(), 'A fresh change carries no failure.');

    change.failure = 'Payload carries no issue id.';
    Assert.isFalse(
      change.isUsable(),
      'A failure set by an adapter is what the processor fails the delivery on.'
    );
  }

  @IsTest
  static void aFreshChangeCarriesNoDateAndNoDescription() {
    InboundChange change = new InboundChange();

    // False, not null. The processor tests these flags directly, and a null Boolean in an if
    // statement throws rather than reading as false.
    Assert.areEqual(false, change.carriesStartDate);
    Assert.areEqual(false, change.carriesDueDate);
    Assert.areEqual(false, change.carriesDescription);
    Assert.isNull(change.sourceCreated);
  }

  @IsTest
  static void carryingAnEmptyValueIsDifferentFromNotCarryingOne() {
    InboundChange change = new InboundChange();
    change.carryDueDate(null);
    change.carryDescription('   ');

    // The whole reason the flags exist: a due date removed in the source arrives as an explicit
    // null, and has to clear the one Salesforce holds.
    Assert.isTrue(change.carriesDueDate, 'An explicit null is still carried.');
    Assert.isNull(change.dueDate);
    Assert.isTrue(change.carriesDescription);
    Assert.isNull(
      change.description,
      'A blank description is an empty one, stored as null rather than as whitespace.'
    );
    Assert.areEqual(
      false,
      change.carriesStartDate,
      'Carrying one field says nothing about another.'
    );
  }

  @IsTest
  static void carryingAValueSetsBothTheValueAndTheFlag() {
    InboundChange change = new InboundChange();
    change.carryStartDate(Date.newInstance(2026, 10, 1));

    Assert.isTrue(change.carriesStartDate);
    Assert.areEqual(Date.newInstance(2026, 10, 1), change.startDate);
  }
}
