/**
 * Calendar days in and out as YYYY-MM-DD, strictly.
 */
@IsTest
private class IsoDateTest {
  @IsTest
  static void readsARealDay() {
    Assert.areEqual(
      Date.newInstance(2026, 9, 30),
      IsoDate.parseDay('2026-09-30')
    );
    Assert.areEqual(
      Date.newInstance(2028, 2, 29),
      IsoDate.parseDay(' 2028-02-29 '),
      'A leap day in a leap year is a real day, and surrounding space is not a reason to refuse.'
    );
  }

  @IsTest
  static void nothingIsNoDate() {
    Assert.isNull(IsoDate.parseDay(null));
    Assert.isNull(IsoDate.parseDay(''));
    Assert.isNull(IsoDate.parseDay('   '));
  }

  @IsTest
  static void anythingElseIsRefusedRatherThanGuessed() {
    List<String> unreadable = new List<String>{
      // Date.valueOf would take this and drop the time; a date-time is not a calendar day.
      '2026-09-30T00:00:00Z',
      '2026-9-3',
      '30/09/2026',
      'next week',
      // Date.newInstance would roll these over into the next month.
      '2026-02-30',
      '2027-02-29',
      '2026-13-01',
      '2026-00-10'
    };
    for (String value : unreadable) {
      try {
        IsoDate.parseDay(value);
        Assert.fail('Should have refused "' + value + '".');
      } catch (IsoDate.UnreadableDateException e) {
        Assert.isTrue(
          e.getMessage().contains(value),
          'The message names what it could not read: ' + e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void formatsBackToTheSameShape() {
    Assert.areEqual('2026-09-03', IsoDate.format(Date.newInstance(2026, 9, 3)));
    Assert.areEqual('0999-01-01', IsoDate.format(Date.newInstance(999, 1, 1)));
    Assert.isNull(IsoDate.format(null));
    Assert.areEqual(
      '2026-12-31',
      IsoDate.format(IsoDate.parseDay('2026-12-31')),
      'A round trip changes nothing.'
    );
  }
}
