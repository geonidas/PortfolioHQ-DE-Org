/**
 * The portrait layout's condition is written three times, and has to be the same condition.
 *
 * boardLayout.PORTRAIT_QUERY is what the JavaScript asks - drag-and-drop turns off, the arrows turn
 * on. boardColumns.css and boardTheme.css repeat it as @media rules, because CSS cannot import a
 * JavaScript constant: one lays out the track, the other sizes and snaps the columns in it. If
 * they drift, a window can be in portrait for the stylesheet and not for the script, and get one
 * column at a time with no arrows to reach the others.
 */
const fs = require("fs");
const path = require("path");
import { PORTRAIT_QUERY } from "c/boardLayout";

const LWC_ROOT = path.resolve(__dirname, "..");
const read = (bundle) =>
  fs.readFileSync(path.join(LWC_ROOT, bundle, `${bundle}.css`), "utf8");

describe("the portrait query", () => {
  it.each(["boardColumns", "boardTheme"])(
    "is the same in %s.css as in boardLayout",
    (bundle) => {
      const queries = Array.from(
        read(bundle).matchAll(/@media\s+([^{]+?)\s*\{/g)
      ).map((match) => match[1].trim());
      expect(queries).toContain(PORTRAIT_QUERY);
      queries
        .filter((query) => query.includes("orientation"))
        .forEach((query) => expect(query).toBe(PORTRAIT_QUERY));
    }
  );
});
