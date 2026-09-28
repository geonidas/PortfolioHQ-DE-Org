/**
 * Accessibility matchers for every LWC Jest suite.
 *
 * toBeAccessible() is sa11y's own. Explicit assertions only, not sa11y's automatic after-each
 * mode: a component test says which rendered states it holds to the bar, so a state nobody
 * asserted is visibly unasserted rather than silently checked or silently skipped.
 *
 * Neither matcher works under fake timers - axe times out - so a test that fakes timers must
 * switch back to real ones before asserting.
 */
const { registerSa11yMatcher } = require("@sa11y/jest");
const { runA11yCheck } = require("@sa11y/matcher");

registerSa11yMatcher();

expect.extend({
  /**
   * A ratchet for violations that are known and scheduled, not waived.
   *
   * Passes only when the rule ids that fail are EXACTLY the ones listed. That makes it fail in
   * both directions, and both are the point:
   * - a new violation appears beside the known one: it is not hidden by the allowance;
   * - the known one is fixed: the assertion fails until it is replaced by toBeAccessible(),
   *   so an allowance cannot outlive the defect it was written for.
   *
   * Runs the same check toBeAccessible() does, with the same default rule set.
   *
   * @param received        the element to check
   * @param expectedRuleIds axe rule ids, e.g. ["aria-allowed-role"]
   */
  async toHaveOnlyKnownA11yViolations(received, expectedRuleIds) {
    const { a11yError } = await runA11yCheck(received);
    const actual = [...new Set(a11yError.violations.map((v) => v.id))].sort();
    const expected = [...new Set(expectedRuleIds)].sort();
    const unexpected = actual.filter((id) => !expected.includes(id));
    const fixed = expected.filter((id) => !actual.includes(id));
    const pass = unexpected.length === 0 && fixed.length === 0;
    return {
      pass,
      message: () => {
        const lines = [];
        if (unexpected.length) {
          lines.push(`New accessibility violations: ${unexpected.join(", ")}.`);
        }
        if (fixed.length) {
          lines.push(
            `No longer violated: ${fixed.join(", ")}. Remove it from the known list, ` +
              "or replace this assertion with toBeAccessible() if the list is now empty."
          );
        }
        return lines.join("\n") || "Violations matched the known list exactly.";
      }
    };
  }
});
