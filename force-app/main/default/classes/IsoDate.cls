/**
 * Calendar dates in the one shape both source systems use for them: YYYY-MM-DD.
 *
 * Jira's duedate and start date, and Asana's due_on, are calendar days, not instants. They are
 * read into Date and never into Datetime, because a Datetime has a time zone and a calendar day
 * does not: midnight UTC is the previous evening west of Greenwich, and a date that went through
 * one would show a day early there. The same rule holds in the browser, where the board never
 * builds a JavaScript Date from one of these strings.
 *
 * Strict on purpose. A value that is not exactly a real YYYY-MM-DD day throws, so a caller can
 * decline to apply it rather than clear or change a date Salesforce already holds on the strength
 * of something it could not read. Date.valueOf alone is not strict: it accepts a date-time string
 * and rolls an impossible day forward.
 */
public class IsoDate {
  private static final Pattern DAY = Pattern.compile(
    '(\\d{4})-(\\d{2})-(\\d{2})'
  );

  public class UnreadableDateException extends Exception {
  }

  /**
   * @param value a YYYY-MM-DD string, as a vendor payload carries it; null or blank is no date
   * @return      the day, or null when there is none
   * @throws UnreadableDateException when the value is present and is not a real day
   */
  public static Date parseDay(Object value) {
    if (value == null) {
      return null;
    }
    String text = String.valueOf(value).trim();
    if (text.length() == 0) {
      return null;
    }
    Matcher parts = DAY.matcher(text);
    if (!parts.matches()) {
      throw new UnreadableDateException(
        'Not a YYYY-MM-DD date: "' + text + '".'
      );
    }
    Integer year = Integer.valueOf(parts.group(1));
    Integer month = Integer.valueOf(parts.group(2));
    Integer day = Integer.valueOf(parts.group(3));
    Date result = month >= 1 &&
      month <= 12 &&
      day >= 1
      ? Date.newInstance(year, month, day)
      : null;
    // Date.newInstance rolls 2026-02-30 over to March 2 rather than refusing it.
    if (
      result == null ||
      result.year() != year ||
      result.month() != month ||
      result.day() != day
    ) {
      throw new UnreadableDateException('No such day: "' + text + '".');
    }
    return result;
  }

  /**
   * A day back to YYYY-MM-DD, for an outbound request body. Built from the parts rather than
   * through Datetime.format, which would apply the running user's time zone to a value that has
   * none.
   */
  public static String format(Date value) {
    if (value == null) {
      return null;
    }
    return String.valueOf(value.year()).leftPad(4, '0') +
      '-' +
      String.valueOf(value.month()).leftPad(2, '0') +
      '-' +
      String.valueOf(value.day()).leftPad(2, '0');
  }

  private IsoDate() {
  }
}
