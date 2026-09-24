/**
 * What the public board brings with it.
 *
 * An LWC import is not conditional: whatever a module imports ships in the bundle of every page
 * that uses it. publicWorkItemBoard runs for anonymous visitors, so everything it reaches - its
 * own imports, the child components its template renders, the stylesheets it pulls in, and all of
 * theirs - is guest-facing code. This walks that graph from the source files and holds it to the
 * rules that keep the public board read only by construction:
 *
 * - The one Apex import in the graph is PublicBoardController.getPublicBoardData, made by the
 *   public board itself. WorkItemBoardController - the class a guest must never reach - is not
 *   imported anywhere in it.
 * - Nothing in it imports lightning/empApi, which LWR sites do not support.
 * - Every module shared with the internal board imports nothing from @salesforce or lightning
 *   at all. That is what lets both boards share them: sharing widens nothing.
 *
 * Read from source rather than from a build, so it runs in the unit suite and fails before a
 * deploy rather than on a public page.
 */
const fs = require("fs");
const path = require("path");
const { parse } = require("@babel/parser");

const LWC_ROOT = path.resolve(__dirname, "..");
const PUBLIC_ROOT = "publicWorkItemBoard";
const INTERNAL_ROOT = "workItemBoard";
const PUBLIC_APEX = "@salesforce/apex/PublicBoardController.getPublicBoardData";

/** c-board-card -> boardCard */
const bundleOfTag = (tag) =>
  tag.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());

function read(bundle, extension) {
  const file = path.join(LWC_ROOT, bundle, `${bundle}.${extension}`);
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
}

/** Every import specifier in a bundle's JS, HTML and CSS, as written. */
function importsOf(bundle) {
  const specifiers = [];
  const js = read(bundle, "js");
  if (js) {
    const ast = parse(js, {
      sourceType: "module",
      plugins: ["decorators-legacy"]
    });
    ast.program.body
      .filter((node) => node.type === "ImportDeclaration")
      .forEach((node) => specifiers.push(node.source.value));
  }
  const html = read(bundle, "html");
  if (html) {
    const withoutComments = html.replace(/<!--[\s\S]*?-->/g, "");
    for (const match of withoutComments.matchAll(/<(c-[a-z0-9-]+)/g)) {
      specifiers.push(`c/${bundleOfTag(match[1])}`);
    }
  }
  const css = read(bundle, "css");
  if (css) {
    for (const match of css.matchAll(/@import\s+['"]([^'"]+)['"]/g)) {
      specifiers.push(match[1]);
    }
  }
  return [...new Set(specifiers)];
}

/** Every bundle reachable from a root, and what each one imports. */
function graphFrom(root) {
  const graph = new Map();
  const queue = [root];
  while (queue.length) {
    const bundle = queue.shift();
    if (graph.has(bundle)) {
      continue;
    }
    const specifiers = importsOf(bundle);
    graph.set(bundle, specifiers);
    specifiers
      .filter((specifier) => specifier.startsWith("c/"))
      .forEach((specifier) => queue.push(specifier.slice(2)));
  }
  return graph;
}

describe("the public board's bundle", () => {
  const guest = graphFrom(PUBLIC_ROOT);
  const internal = graphFrom(INTERNAL_ROOT);
  const shared = [...guest.keys()].filter((bundle) => internal.has(bundle));

  it("finds the modules it is meant to find", () => {
    // A walker that silently found nothing would pass every rule below.
    [
      "boardCard",
      "boardEpicCard",
      "boardToolbar",
      "boardLayout",
      "boardModel",
      "boardTheme"
    ].forEach((bundle) => expect(guest.has(bundle)).toBe(true));
    expect(internal.get(INTERNAL_ROOT)).toContain(
      "@salesforce/apex/WorkItemBoardController.getBoardData"
    );
  });

  it("imports one Apex method, from the public controller, and only at the top", () => {
    const apex = [];
    guest.forEach((specifiers, bundle) =>
      specifiers
        .filter((s) => s.startsWith("@salesforce/apex/"))
        .forEach((s) => apex.push(`${bundle} -> ${s}`))
    );
    expect(apex).toEqual([`${PUBLIC_ROOT} -> ${PUBLIC_APEX}`]);
  });

  it("never reaches the internal controller or the internal board", () => {
    guest.forEach((specifiers) =>
      specifiers.forEach((s) =>
        expect(s).not.toMatch(/WorkItemBoardController/)
      )
    );
    expect(guest.has(INTERNAL_ROOT)).toBe(false);
  });

  it("never imports lightning/empApi", () => {
    guest.forEach((specifiers) =>
      expect(specifiers).not.toContain("lightning/empApi")
    );
  });

  it("shares only modules that import nothing from the platform", () => {
    expect(shared.length).toBeGreaterThan(0);
    shared.forEach((bundle) => {
      const platform = guest
        .get(bundle)
        .filter(
          (s) => s.startsWith("@salesforce/") || s.startsWith("lightning/")
        );
      expect({ bundle, platform }).toEqual({ bundle, platform: [] });
    });
  });
});
