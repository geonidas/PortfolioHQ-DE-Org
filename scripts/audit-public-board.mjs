/**
 * The public board's accessibility, checked in a real browser as an anonymous visitor.
 *
 *   node scripts/audit-public-board.mjs [focus-screenshot.png]
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
 * Scoped to the board component. Anything found outside it - the template's "Skip to Main" link,
 * which sits outside every landmark and uses the browser's default ring - belongs to the site
 * template and is reported separately rather than failed. Exits 1 on any axe violation in the
 * board, any board stop without a visible ring or out of view, or a disclosure that does not open
 * on Enter and close on Escape with focus back on its header.
 */
import { readFileSync, writeFileSync } from "node:fs";
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
// Optional: where to save a screenshot of a focused card beside an open one.
const [focusShot] = process.argv.slice(2);

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

const SCENARIOS = [
  { viewport: desktop, name: "tasks, by due date (the default)", steps: [] },
  {
    viewport: desktop,
    name: "tasks, by priority",
    steps: [choose("sort", "priority")],
    watchRequests: true
  },
  {
    viewport: desktop,
    name: "tasks, a card open",
    steps: [openCardScript("WI-0005")]
  },
  {
    viewport: desktop,
    name: "epics, an epic open",
    steps: [choose("view", "epics"), openFirstEpic]
  },
  { viewport: desktop, name: "one source", steps: [choose("source", "Asana")] },
  { viewport: phone, name: "portrait, by due date (the default)", steps: [] },
  {
    viewport: phone,
    name: "portrait, by priority",
    steps: [choose("sort", "priority")],
    watchRequests: true
  },
  {
    viewport: phone,
    name: "portrait, a card open",
    steps: [openCardScript("WI-0003")]
  },
  { viewport: phone, name: "portrait, last column", steps: [pressNextArrow] }
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

await withGuestBrowser(async (cdp) => {
  for (const scenario of SCENARIOS) {
    await loadBoard(cdp, scenario.viewport);
    // Every request the steps cause, when the scenario asks. A sort re-renders what the board
    // already holds; a request to Apex here would mean it had started asking the server.
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
    const result = await axe(cdp);
    if (result.board.length || apexRequests.length) {
      failed = true;
    }
    report.axe.push({
      viewport: scenario.viewport.name,
      scenario: scenario.name,
      ...(scenario.watchRequests
        ? { requestsWhileSorting: requests.length, apexRequests }
        : {}),
      ...result
    });
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

console.log(JSON.stringify(report, null, 1));
process.exitCode = failed ? 1 : 0;
