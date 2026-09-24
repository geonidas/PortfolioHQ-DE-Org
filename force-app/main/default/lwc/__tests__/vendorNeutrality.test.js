/**
 * The client never names a vendor.
 *
 * Source labels, accents and capabilities reach the boards as data from BoardSourceRules. A
 * vendor's name written into component source is either a branch on that vendor or copy that
 * will be wrong for the next one, so this fails on any occurrence in LWC JS, HTML or CSS -
 * strings, template text, attribute values, identifiers, class names, selectors.
 *
 * Comments are not source and are never flagged. They are removed with a real tokenizer rather
 * than a regular expression, because the scan build 07 wrote for @AuraEnabled flagged its own
 * documentation, and a regex that strips "// ..." also strips half of "https://...". Test
 * folders are out of scope: a fixture that carries a source label is data arriving as data,
 * which is exactly the rule.
 */
const fs = require("fs");
const path = require("path");
const { parse } = require("@babel/parser");

const LWC_ROOT = path.resolve(__dirname, "..");
const VENDOR = /jira|asana/gi;
const SKIPPED_DIRS = new Set(["__tests__", "__mocks__", "jest-mocks"]);

/** Replace a range with spaces, keeping newlines, so reported line numbers stay true. */
function blank(source, start, end) {
  return (
    source.slice(0, start) +
    source.slice(start, end).replace(/[^\n]/g, " ") +
    source.slice(end)
  );
}

function withoutJsComments(source) {
  const ast = parse(source, {
    sourceType: "module",
    plugins: ["decorators-legacy"]
  });
  // Last to first, so earlier offsets stay valid as later ranges are blanked.
  return [...ast.comments]
    .sort((a, b) => b.start - a.start)
    .reduce((text, comment) => blank(text, comment.start, comment.end), source);
}

function withoutHtmlComments(source) {
  return source.replace(/<!--[\s\S]*?-->/g, (comment) =>
    comment.replace(/[^\n]/g, " ")
  );
}

/** CSS comments, skipping quoted strings so a "/*" inside a string starts nothing. */
function withoutCssComments(source) {
  let out = "";
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === '"' || ch === "'") {
      let j = i + 1;
      while (j < source.length && source[j] !== ch) {
        j += source[j] === "\\" ? 2 : 1;
      }
      out += source.slice(i, j + 1);
      i = j + 1;
    } else if (ch === "/" && source[i + 1] === "*") {
      const close = source.indexOf("*/", i + 2);
      const end = close === -1 ? source.length : close + 2;
      out += source.slice(i, end).replace(/[^\n]/g, " ");
      i = end;
    } else {
      out += ch;
      i++;
    }
  }
  return out;
}

const STRIPPERS = {
  ".js": withoutJsComments,
  ".html": withoutHtmlComments,
  ".css": withoutCssComments
};

/** Every vendor name left once comments are gone, as { line, match, text }. */
function vendorLiterals(fileName, source) {
  const strip = STRIPPERS[path.extname(fileName)];
  const code = strip(source);
  const found = [];
  code.split("\n").forEach((text, index) => {
    for (const match of text.matchAll(VENDOR)) {
      found.push({ line: index + 1, match: match[0], text: text.trim() });
    }
  });
  return found;
}

function sourceFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      return SKIPPED_DIRS.has(entry.name) ? [] : sourceFiles(full);
    }
    return STRIPPERS[path.extname(entry.name)] ? [full] : [];
  });
}

describe("the scanner itself", () => {
  // These exist so the real scan below cannot pass vacuously: each proves one thing the scan
  // must catch or must leave alone.
  it("flags a vendor name in a string, a template and an identifier", () => {
    const source = [
      'const label = "Jira";',
      "const note = `until ${who} Asana confirms`;",
      "const isJira = true;"
    ].join("\n");
    expect(vendorLiterals("x.js", source).map((f) => f.line)).toEqual([
      1, 2, 3
    ]);
  });

  it("leaves a comment that explains the rule alone", () => {
    const source = [
      "// Never write Jira or Asana here - labels arrive as data.",
      "/* The same rule, in a block: no Asana. */",
      "const label = card.sourceLabel;"
    ].join("\n");
    expect(vendorLiterals("x.js", source)).toEqual([]);
  });

  it("does not mistake the slashes in a URL for a comment", () => {
    const source =
      'const url = "https://example.test//path"; const s = "jira";';
    expect(vendorLiterals("x.js", source)).toHaveLength(1);
  });

  it("parses a component with decorators", () => {
    const source = [
      'import { LightningElement, api } from "lwc";',
      "export default class X extends LightningElement {",
      "  @api label = 'Asana';",
      "}"
    ].join("\n");
    expect(vendorLiterals("x.js", source).map((f) => f.line)).toEqual([3]);
  });

  it("flags template text and attribute values, not template comments", () => {
    const source = [
      "<!-- The Jira rule: nothing vendor-named below. -->",
      "<p>Synced from Jira</p>",
      '<span title="Asana task"></span>'
    ].join("\n");
    expect(vendorLiterals("x.html", source).map((f) => f.line)).toEqual([2, 3]);
  });

  it("flags selectors and values in CSS, not CSS comments", () => {
    const source = [
      "/* One accent per source, never per vendor: no .jira here. */",
      ".jira-accent { color: red; }",
      '.x::before { content: "/* Asana */"; }'
    ].join("\n");
    expect(vendorLiterals("x.css", source).map((f) => f.line)).toEqual([2, 3]);
  });
});

describe("LWC source", () => {
  const files = sourceFiles(LWC_ROOT);

  it("finds the component source it is meant to scan", () => {
    const names = files.map((file) => path.relative(LWC_ROOT, file));
    expect(names).toEqual(
      expect.arrayContaining([
        "workItemBoard/workItemBoard.js",
        "workItemBoard/workItemBoard.html",
        "publicWorkItemBoard/publicWorkItemBoard.css"
      ])
    );
    expect(names.some((name) => name.includes("__tests__"))).toBe(false);
  });

  it("names no vendor anywhere outside a comment", () => {
    const findings = files.flatMap((file) =>
      vendorLiterals(file, fs.readFileSync(file, "utf8")).map(
        (f) => `${path.relative(LWC_ROOT, file)}:${f.line}  ${f.text}`
      )
    );
    // Compared as a list so a failure prints every offending line, not just a count.
    expect(findings).toEqual([]);
  });
});
