/**
 * What the portfolio site brings with it.
 *
 * The portfolio is served to anonymous visitors, and it is meant to need nothing from the org: no
 * Apex class, no object, no permission for the site guest. Class access is granted per class, so
 * the way to keep that true is to keep it out of the bundles, and this holds every portfolio
 * bundle to it, from source, before a deploy:
 *
 * - Every import in a portfolio bundle is lwc, another portfolio bundle, or the one static
 *   resource. An @salesforce/apex import (or a wire adapter, a schema import, lightning/*) is a
 *   new dependency on the org, and it is a decision - not something to arrive through a content
 *   edit - so it fails here until this test is changed on purpose.
 * - No portfolio bundle imports a board bundle, or the other way round. The two projects share a
 *   site host and a guest user, and nothing else.
 */
const fs = require("fs");
const path = require("path");
const { parse } = require("@babel/parser");

const LWC_ROOT = path.resolve(__dirname, "..");
const ALLOWED_RESOURCE = "@salesforce/resourceUrl/portfolio_assets";

const bundles = fs
  .readdirSync(LWC_ROOT, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && /^portfolio/.test(entry.name))
  .map((entry) => entry.name);

/** Every import specifier in a bundle's JS, and every c-* tag and @import in its HTML and CSS. */
function specifiersOf(bundle) {
  const found = [];
  const dir = path.join(LWC_ROOT, bundle);
  for (const file of fs.readdirSync(dir)) {
    const full = path.join(dir, file);
    if (!fs.statSync(full).isFile()) continue;
    const source = fs.readFileSync(full, "utf8");
    if (file.endsWith(".js")) {
      parse(source, { sourceType: "module", plugins: ["decorators-legacy"] })
        .program.body.filter((node) => node.type === "ImportDeclaration")
        .forEach((node) => found.push(node.source.value));
    } else if (file.endsWith(".css")) {
      for (const match of source.matchAll(/@import\s+["']([^"']+)["']/g)) {
        found.push(match[1]);
      }
    } else if (file.endsWith(".html")) {
      // <c-portfolio-nav> -> c/portfolioNav
      for (const match of source.matchAll(/<c-([a-z0-9-]+)/g)) {
        found.push(
          `c/${match[1].replace(/-([a-z0-9])/g, (_, ch) => ch.toUpperCase())}`
        );
      }
    }
  }
  return found;
}

const isAllowed = (specifier) =>
  specifier === "lwc" ||
  specifier === ALLOWED_RESOURCE ||
  /^c\/portfolio[A-Za-z]*$/.test(specifier);

describe("portfolio bundles", () => {
  it("finds the bundles it is meant to check", () => {
    expect(bundles).toEqual(
      expect.arrayContaining([
        "portfolioPage",
        "portfolioContent",
        "portfolioTheme"
      ])
    );
  });

  it.each(bundles)(
    "%s imports only lwc, other portfolio bundles and the portfolio_assets resource",
    (bundle) => {
      const unexpected = specifiersOf(bundle).filter(
        (specifier) => !isAllowed(specifier)
      );
      expect(unexpected).toEqual([]);
    }
  );

  it("does not share a bundle with the boards", () => {
    const shared = bundles.flatMap((bundle) =>
      specifiersOf(bundle).filter((specifier) => /^c\/board/.test(specifier))
    );
    expect(shared).toEqual([]);
  });

  it("is not imported by a board bundle", () => {
    const boardBundles = fs
      .readdirSync(LWC_ROOT, { withFileTypes: true })
      .filter(
        (entry) =>
          entry.isDirectory() &&
          /^(board|workItemBoard|publicWorkItemBoard)/.test(entry.name)
      )
      .map((entry) => entry.name);
    expect(boardBundles.length).toBeGreaterThan(0);
    const leaks = boardBundles.flatMap((bundle) => {
      const dir = path.join(LWC_ROOT, bundle);
      return fs
        .readdirSync(dir)
        .filter((file) => /\.(js|html|css)$/.test(file))
        .filter((file) =>
          /c\/portfolio|<c-portfolio/.test(
            fs.readFileSync(path.join(dir, file), "utf8")
          )
        )
        .map((file) => `${bundle}/${file}`);
    });
    expect(leaks).toEqual([]);
  });
});
