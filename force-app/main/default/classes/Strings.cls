/**
 * String helpers that four classes used to carry private copies of.
 *
 * Both exist because Salesforce field lengths are hard limits: a body over the field length
 * fails the whole DML, and a log row that fails to write is a log row nobody reads.
 */
public class Strings {
  private static final String ELLIPSIS = '...';

  /**
   * Cut a value to fit a field, ending in an ellipsis so a reader can tell it was cut.
   *
   * @param value     the text, null-safe
   * @param maxLength the field length; the result never exceeds it
   */
  public static String truncate(String value, Integer maxLength) {
    if (value == null || value.length() <= maxLength) {
      return value;
    }
    if (maxLength <= ELLIPSIS.length()) {
      return value.substring(0, maxLength);
    }
    return value.substring(0, maxLength - ELLIPSIS.length()) + ELLIPSIS;
  }

  /** An exception as one line: its type and its message. For log rows and result messages. */
  public static String describe(Exception e) {
    return e == null ? '' : e.getTypeName() + ': ' + e.getMessage();
  }

  private Strings() {
  }
}
