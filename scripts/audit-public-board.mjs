/**
 * The public board's accessibility, checked in a real browser as an anonymous visitor.
 *
 *   node scripts/audit-public-board.mjs [focus-screenshot.png] [--shots=<dir>]
 *
 * Two checks the Jest gate cannot make, because jsdom has no layout:
 *
 * 1. axe-core - the engine sa11y runs, from this project's own node_modules - over the board in
 *    the states a visitor can put it in: the task view by due date and by priority, a card open,
 *    the epic view with an epic open, one source chosen; and at 375px in portrait by each sort,
 *    with a card open and at the last column. Colour contrast is checked here and nowhere else in
 *    the suite. Build 09: changing the sort must send nothing - it is client-side (decision 5) -
 *    so the requests made while it changes are counted, and any Apex request fails the audit.
 * 2. A keyboard walkthrough at both sizes: Tab through the board and record every stop, whether
 *    it shows a focus ring and whether it scrolled into view; then Enter opens a card and Escape
 *    closes it with focus back on its header.
 *
 * Build 10: the featured epic. Which epic is featured is org data, so the audit sets it - through
 * FeaturedEpicService, as the owner, with the sf CLI - runs every state under it, and puts back
 * exactly the value it found, whatever happens. Build 09's states run with WI-0000 featured, which
 * is the view they were written for: the board opens on Tasks. Then, at both sizes: featured in
 * Tasks, featured with the Source filter excluding the featured epic's source, none in Epics (where
 * a visit then opens) and none in Tasks. Each checks what it shows, not only that axe is quiet;
 * the 375px ones measure that the sentence fits and sits below the toolbar; and a view or source
 * change must send nothing, like a sort. Each featured state gets its own fresh browser, so
 * nothing one state loaded can be served in the next. With --shots, each build 10 state is saved
 * as a screenshot, the 375px ones through device emulation.
 *
 * Scoped to the board component. Anything found outside it - the template's "Skip to Main" link,
 * which sits outside every landmark and uses the browser's default ring - belongs to the site
 * template and is reported separately rather than failed. Exits 1 on any axe violation in the
 * board, any board stop without a visible ring or out of view, a disclosure that does not open
 * on Enter and close on Escape with focus back on its header, a state that shows the wrong thing,
 * or an Apex request while a watched state is being set up.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import {
  DEEP,
  VIEWPORTS,
  evaluate,
  loadBoard,
  openCardScript,
  sleep,
  withGuestBrowser
} from "./lib/guest-browser.mjs";

const AXE = readFileSync(
  new URL("../node_modules/axe-core/axe.min.js", import.meta.url),
  "utf8"
);
const BOARD = "c-public-work-item-board";

const [desktop, phone] = VIEWPORTS;
const args = process.argv.slice(2);
// Optional: where to save a screenshot of a focused card beside an open one.
const focusShot = args.find((arg) => !arg.startsWith("--"));
// Optional: a folder for a screenshot of each build 10 state.
const shotsArg = args.find((arg) => arg.startsWith("--shots="));
const shotsDir = shotsArg ? shotsArg.slice("--shots=".length) : null;

// ---------- the featured epic, set through the org (build 10) ----------

const ORG = process.env.AUDIT_ORG || "MyScratchOrg";
const FEATURED = "WI-0000";
const NONE_NOTE = "No epic is featured right now, so no epic tasks are shown.";

function apex(code) {
  const out = execFileSync("sf", ["apex", "run", "--target-org", ORG], {
    input: code,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "ignore"]
  });
  return out
    .split("\n")
    .filter((line) => line.includes("|DEBUG|>>>"))
    .map((line) => line.slice(line.indexOf(">>>") + 4).trim());
}

/** The setting's raw value, resolved or not, so it can be put back exactly. */
function storedValue() {
  const [line] = apex(
    "System.debug('>>> ' + Featured_Epic__c.getOrgDefaults().Epic_Id__c);"
  );
  return line === "null" ? null : line;
}

/** Features an epic by record number, or none, through the service the board's button uses. */
function feature(recordNumber) {
  const [line] = apex(
    recordNumber
      ? `FeaturedEpicService.Result r = FeaturedEpicService.feature([SELECT Id FROM Work_Item__c WHERE Name = '${recordNumber}'].Id);
         System.debug('>>> ' + (r.saved || !r.refused) + ' ' + FeaturedEpicService.read());`
      : `FeaturedEpicService.clear();
         System.debug('>>> true ' + FeaturedEpicService.read());`
  );
  const [ok, now] = (line || "").split(" ");
  if (ok !== "true" || (recordNumber ? now === "null" : now !== "null")) {
    throw new Error(
      `Could not set the featured epic to ${recordNumber}: ${line}`
    );
  }
}

/** Puts the setting back as it was found - an unresolvable Id included - as the owner. */
function restore(value) {
  apex(`Featured_Epic__c s = Featured_Epic__c.getOrgDefaults();
    if (s.Id == null) { s.SetupOwnerId = UserInfo.getOrganizationId(); }
    s.Epic_Id__c = ${value ? `'${value}'` : "null"};
    upsert s;
    System.debug('>>> ' + Featured_Epic__c.getOrgDefaults().Epic_Id__c);`);
}

/**
 * Page-side: what the board shows about the featured epic, as problems. Empty when it shows what
 * it should. At a phone width, the sentence must fit the screen and sit below the toolbar.
 */
const expectFeatured = ({
  view,
  note,
  indicator,
  hidden = [],
  narrow = false
}) => `(() => {
  ${DEEP}
  const problems = [];
  const select = deep('select[data-filter="view"]')[0];
  if (select.value !== ${JSON.stringify(view)}) problems.push("view is " + select.value);
  const noteEl = deep("[data-featured-note]")[0];
  const text = noteEl ? noteEl.textContent.trim() : null;
  const wanted = ${JSON.stringify(note)};
  if (wanted instanceof Array ? !text.startsWith(wanted[0]) : text !== wanted) {
    problems.push("the sentence is " + JSON.stringify(text));
  }
  const marks = deep("c-board-epic-card").map((c) => c.shadowRoot.querySelector("[data-featured]")).filter(Boolean);
  if (marks.length !== ${indicator ? 1 : 0}) problems.push(marks.length + " epics carry the indicator");
  const shown = deep("c-board-card").map((c) => c.shadowRoot.querySelector("article").dataset.key);
  ${JSON.stringify(hidden)}.forEach((n) => { if (shown.includes(n)) problems.push(n + " should not be shown"); });
  if (${narrow}) {
    if (document.documentElement.scrollWidth > innerWidth) problems.push("the page scrolls sideways: " + document.documentElement.scrollWidth);
    if (text) {
      const n = noteEl.getBoundingClientRect();
      const t = deep("c-board-toolbar")[0].getBoundingClientRect();
      if (n.left < 0 || n.right > innerWidth) problems.push("the sentence overflows: " + Math.round(n.left) + "-" + Math.round(n.right));
      if (n.top < t.bottom) problems.push("the sentence is not below the toolbar");
    }
  }
  return problems;
})()`;

/** Page-side: sets one of the toolbar's selects, as a visitor choosing an option would. */
const choose = (filter, value) => `(() => {
  ${DEEP}
  const select = deep('select[data-filter="${filter}"]')[0];
  select.value = ${JSON.stringify(value)};
  select.dispatchEvent(new Event("change"));
  return true;
})()`;

const openFirstEpic = `(() => {
  ${DEEP}
  const epic = deep("c-board-epic-card")[0];
  if (!epic) return false;
  epic.shadowRoot.querySelector("[data-disclosure]").click();
  return true;
})()`;

const pressNextArrow = `(() => {
  ${DEEP}
  const arrow = deep('[data-arrow="next"]')[0];
  if (!arrow) return false;
  arrow.click();
  return true;
})()`;

// Build 09's states, with WI-0000 featured so the board opens on Tasks as they expect, then
// build 10's. The Epics view with an epic open shows the indicator.
const SHOWING = ["Showing tasks from"];
const SOURCE_NOTE =
  "The featured epic's tasks are under Jira. Choose Jira or All sources to see them.";
const SCENARIOS = [
  {
    viewport: desktop,
    name: "tasks, by due date (the default)",
    featured: true,
    steps: [],
    check: expectFeatured({ view: "tasks", note: SHOWING, indicator: false }),
    shot: "featured-tasks"
  },
  {
    viewport: desktop,
    name: "tasks, by priority",
    featured: true,
    steps: [choose("sort", "priority")],
    watchRequests: true
  },
  {
    viewport: desktop,
    name: "tasks, a card open",
    featured: true,
    steps: [openCardScript("WI-0005")]
  },
  {
    viewport: desktop,
    name: "epics, an epic open",
    featured: true,
    steps: [choose("view", "epics"), openFirstEpic],
    watchRequests: true,
    check: expectFeatured({ view: "epics", note: "", indicator: true }),
    shot: "featured-epics"
  },
  {
    viewport: desktop,
    name: "one source",
    featured: true,
    steps: [choose("source", "Asana")],
    watchRequests: true,
    // Build 10: Asana excludes the featured epic's source, so this is also that state.
    check: expectFeatured({
      view: "tasks",
      note: SOURCE_NOTE,
      indicator: false
    }),
    shot: "featured-source-excluded"
  },
  {
    viewport: phone,
    name: "portrait, by due date (the default)",
    featured: true,
    steps: [],
    check: expectFeatured({
      view: "tasks",
      note: SHOWING,
      indicator: false,
      narrow: true
    }),
    shot: "featured-tasks"
  },
  {
    viewport: phone,
    name: "portrait, by priority",
    featured: true,
    steps: [choose("sort", "priority")],
    watchRequests: true
  },
  {
    viewport: phone,
    name: "portrait, a card open",
    featured: true,
    steps: [openCardScript("WI-0003")]
  },
  {
    viewport: phone,
    name: "portrait, last column",
    featured: true,
    steps: [pressNextArrow]
  },
  {
    viewport: phone,
    name: "portrait, featured epic's source excluded",
    featured: true,
    steps: [choose("source", "Asana")],
    watchRequests: true,
    check: expectFeatured({
      view: "tasks",
      note: SOURCE_NOTE,
      indicator: false,
      narrow: true
    }),
    shot: "featured-source-excluded"
  },
  // Build 10, none featured: a visit opens on Epics, and Tasks holds no epic work.
  {
    viewport: desktop,
    name: "none featured, epics (the default)",
    featured: false,
    steps: [],
    check: expectFeatured({ view: "epics", note: "", indicator: false }),
    shot: "none-epics"
  },
  {
    viewport: desktop,
    name: "none featured, tasks",
    featured: false,
    steps: [choose("view", "tasks")],
    watchRequests: true,
    check: expectFeatured({
      view: "tasks",
      note: NONE_NOTE,
      indicator: false,
      hidden: ["WI-0002", "WI-0003", "WI-0005", "WI-0006"]
    }),
    shot: "none-tasks"
  },
  {
    viewport: phone,
    name: "portrait, none featured, epics (the default)",
    featured: false,
    steps: [],
    check: expectFeatured({
      view: "epics",
      note: "",
      indicator: false,
      narrow: true
    }),
    shot: "none-epics"
  },
  {
    viewport: phone,
    name: "portrait, none featured, tasks",
    featured: false,
    steps: [choose("view", "tasks")],
    watchRequests: true,
    check: expectFeatured({
      view: "tasks",
      note: NONE_NOTE,
      indicator: false,
      hidden: ["WI-0002", "WI-0003", "WI-0005", "WI-0006"],
      narrow: true
    }),
    shot: "none-tasks"
  }
];

async function axe(cdp) {
  await evaluate(cdp, `${AXE}; true`);
  return evaluate(
    cdp,
    `(async () => {
      const summarise = (results) => results.violations.map((v) => ({
        rule: v.id,
        impact: v.impact,
        nodes: v.nodes.length,
        example: v.nodes[0] && v.nodes[0].target.join(" ")
      }));
      const board = await axe.run({ include: [["${BOARD}"]] }, { resultTypes: ["violations"] });
      const page = await axe.run(document, { resultTypes: ["violations"] });
      const boardRules = new Set(board.violations.map((v) => v.id));
      return {
        board: summarise(board),
        outsideBoard: summarise(page).filter((v) => !boardRules.has(v.rule))
      };
    })()`
  );
}

/** Page-side: what has focus now, through every shadow root, and whether it shows a ring. */
const FOCUS = `(() => {
  let el = document.activeElement;
  while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
  if (!el || el === document.body) return { name: "body" };
  const card = el.closest("article");
  const name =
    el.dataset.filter || el.dataset.action ||
    (el.dataset.arrow && "arrow-" + el.dataset.arrow) ||
    (el.hasAttribute("data-disclosure") && "card " + (card ? card.dataset.key : "?")) ||
    el.tagName.toLowerCase();
  const style = getComputedStyle(el);
  // The board draws a 2px Ink outline. "auto" is the browser's own ring, which the site
  // template's skip link uses - visible, and not the board's to restyle.
  const ring =
    style.outlineStyle === "auto" ||
    (style.outlineStyle !== "none" && parseFloat(style.outlineWidth) >= 2)
      ? style.outlineStyle + " " + style.outlineWidth + " " + style.outlineColor
      : null;
  const box = el.getBoundingClientRect();
  const inView = box.bottom > 0 && box.top < innerHeight && box.right > 0 && box.left < innerWidth;
  // Inside the board component's shadow tree, at any depth - or not, like the template's links.
  let root = el.getRootNode();
  let inBoard = false;
  while (root && root.host) {
    if (root.host.tagName === "${BOARD.toUpperCase()}") inBoard = true;
    root = root.host.getRootNode();
  }
  return { name, ring, inView, inBoard, expanded: el.getAttribute("aria-expanded") };
})()`;

async function key(cdp, name) {
  const codes = { Tab: 9, Enter: 13, Escape: 27 };
  const base = {
    key: name,
    code: name,
    windowsVirtualKeyCode: codes[name],
    nativeVirtualKeyCode: codes[name]
  };
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    ...base,
    ...(name === "Enter" ? { text: "\r" } : {})
  });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  await sleep(150);
}

async function walkthrough(cdp) {
  const stops = [];
  for (let i = 0; i < 40; i++) {
    await key(cdp, "Tab");
    const focus = await evaluate(cdp, FOCUS);
    if (focus.name === "body" || stops.some((s) => s.name === focus.name)) {
      break;
    }
    stops.push(focus);
  }
  // Back to the first card, open it from the keyboard, close it with Escape.
  const firstCard = stops.find((s) => s.name.startsWith("card "));
  const disclosure = { opened: null, closed: null, focusBack: null };
  if (firstCard) {
    await evaluate(
      cdp,
      `(() => { ${DEEP}
        const card = deep("c-board-card").find((n) => n.shadowRoot.querySelector("article").dataset.key === ${JSON.stringify(firstCard.name.slice(5))});
        card.shadowRoot.querySelector("[data-disclosure]").focus(); return true; })()`
    );
    await key(cdp, "Enter");
    disclosure.opened = (await evaluate(cdp, FOCUS)).expanded;
    await key(cdp, "Escape");
    const after = await evaluate(cdp, FOCUS);
    disclosure.closed = after.expanded;
    disclosure.focusBack = after.name === firstCard.name;
  }
  return { stops, disclosure };
}

const report = { axe: [], keyboard: [] };
let failed = false;

async function runScenario(cdp, scenario) {
  await loadBoard(cdp, scenario.viewport);
  // Every request the steps cause, when the scenario asks. A sort, a view or a source re-renders
  // what the board already holds; a request to Apex here would mean it had started asking.
  const requests = [];
  let stopWatching = () => {};
  if (scenario.watchRequests) {
    await cdp.send("Network.enable");
    stopWatching = cdp.on("Network.requestWillBeSent", (params) =>
      requests.push(params.request.url)
    );
  }
  for (const step of scenario.steps) {
    if (!(await evaluate(cdp, step))) {
      throw new Error(`Could not set up "${scenario.name}"`);
    }
    await sleep(1200);
  }
  stopWatching();
  const apexRequests = requests.filter((url) => /apex|aura/i.test(url));
  const problems = scenario.check ? await evaluate(cdp, scenario.check) : [];
  const result = await axe(cdp);
  if (result.board.length || apexRequests.length || problems.length) {
    failed = true;
  }
  if (shotsDir && scenario.shot) {
    const { data } = await cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: true
    });
    const file = path.join(
      shotsDir,
      `step-04-${scenario.shot}-public-${scenario.viewport.name}.png`
    );
    writeFileSync(file, Buffer.from(data, "base64"));
  }
  report.axe.push({
    viewport: scenario.viewport.name,
    featured: scenario.featured ? FEATURED : "none",
    scenario: scenario.name,
    ...(scenario.watchRequests
      ? { requestsWhileSettingUp: requests.length, apexRequests }
      : {}),
    ...(scenario.check ? { problems } : {}),
    ...result
  });
}

const found = storedValue();
report.featuredBefore = found;
try {
  // WI-0000 featured: build 09's states, the keyboard walkthrough and the focus shot, all on the
  // Tasks view the board now opens on.
  feature(FEATURED);
  await withGuestBrowser(async (cdp) => {
    for (const scenario of SCENARIOS.filter((s) => s.featured)) {
      await runScenario(cdp, scenario);
    }
    for (const viewport of VIEWPORTS) {
      await loadBoard(cdp, viewport);
      const walk = await walkthrough(cdp);
      const unringed = walk.stops.filter((s) => !s.ring || !s.inView);
      // Only the board's own stops can fail it; the template's are reported, not failed.
      if (
        unringed.some((s) => s.inBoard) ||
        walk.disclosure.opened !== "true" ||
        walk.disclosure.closed !== "false" ||
        !walk.disclosure.focusBack
      ) {
        failed = true;
      }
      report.keyboard.push({ viewport: viewport.name, ...walk, unringed });
    }
    if (focusShot) {
      // Open one card with the mouse, then Tab to another: the open card and the focused header
      // side by side, to show the two states do not look alike.
      await loadBoard(cdp, desktop);
      await evaluate(cdp, openCardScript("WI-0005"));
      await sleep(500);
      for (let i = 0; i < 10; i++) {
        await key(cdp, "Tab");
        if ((await evaluate(cdp, FOCUS)).name === "card WI-0002") {
          break;
        }
      }
      const { data } = await cdp.send("Page.captureScreenshot", {
        format: "png"
      });
      writeFileSync(focusShot, Buffer.from(data, "base64"));
      report.focusShot = focusShot;
    }
  });
  // None featured, in a fresh browser.
  feature(null);
  await withGuestBrowser(async (cdp) => {
    for (const scenario of SCENARIOS.filter((s) => !s.featured)) {
      await runScenario(cdp, scenario);
    }
  });
} finally {
  restore(found);
  report.featuredAfter = storedValue();
  if (report.featuredAfter !== found) {
    failed = true;
  }
}

console.log(JSON.stringify(report, null, 1));
process.exitCode = failed ? 1 : 0;
