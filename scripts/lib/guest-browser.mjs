/**
 * Headless Chrome as an anonymous visitor to the public board, driven over the DevTools protocol.
 * Shared by capture-public-board.mjs and audit-public-board.mjs.
 *
 * A fresh profile every run, so no session and no cookies: what it sees is what a guest gets.
 * Device emulation rather than --window-size, because headless Chrome will not size a window
 * below about 500px - a "375px" window that way is a 500px page cropped.
 */
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export const BOARD_URL =
  "https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board";
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9333;

export const VIEWPORTS = [
  { name: "desktop", width: 1440, height: 1000, scale: 1, mobile: false },
  { name: "375", width: 375, height: 812, scale: 2, mobile: true }
];

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function pageSocketUrl() {
  for (let attempt = 0; attempt < 50; attempt++) {
    try {
      const targets = await (
        await fetch(`http://127.0.0.1:${PORT}/json`)
      ).json();
      const page = targets.find((t) => t.type === "page");
      if (page) {
        return page.webSocketDebuggerUrl;
      }
    } catch {
      // Not listening yet.
    }
    await sleep(200);
  }
  throw new Error("Chrome did not start");
}

function connect(url) {
  const socket = new WebSocket(url);
  let next = 0;
  const pending = new Map();
  const listeners = [];
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    } else if (message.method) {
      listeners.forEach((listener) => listener(message));
    }
  });
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++next;
      pending.set(id, (message) =>
        message.error
          ? reject(new Error(message.error.message))
          : resolve(message.result)
      );
      socket.send(JSON.stringify({ id, method, params }));
    });
  const once = (method) =>
    new Promise((resolve) =>
      listeners.push((m) => m.method === method && resolve(m))
    );
  // Every event of one kind until the returned function is called. Build 09: the audit counts
  // the requests a sort change makes, which should be none.
  const on = (method, handler) => {
    const listener = (m) => m.method === method && handler(m.params);
    listeners.push(listener);
    return () => {
      const at = listeners.indexOf(listener);
      if (at >= 0) {
        listeners.splice(at, 1);
      }
    };
  };
  return new Promise((resolve) =>
    socket.addEventListener("open", () =>
      resolve({ send, once, on, close: () => socket.close() })
    )
  );
}

/** Runs `work(cdp)` in a fresh guest browser and always cleans the browser up afterwards. */
export async function withGuestBrowser(work) {
  const profile = mkdtempSync(path.join(tmpdir(), "phq-guest-"));
  const chrome = spawn(
    CHROME,
    [
      "--headless=new",
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--hide-scrollbars",
      "about:blank"
    ],
    { stdio: "ignore" }
  );
  try {
    const cdp = await connect(await pageSocketUrl());
    await cdp.send("Page.enable");
    try {
      return await work(cdp);
    } finally {
      cdp.close();
    }
  } finally {
    // Chrome keeps writing to its profile until it has exited.
    const exited = new Promise((resolve) => chrome.once("exit", resolve));
    chrome.kill();
    await exited;
    rmSync(profile, { recursive: true, force: true, maxRetries: 5 });
  }
}

/** Opens the board at a viewport and waits for it to render: the site boots, then the wire. */
export async function loadBoard(cdp, viewport) {
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: viewport.width,
    height: viewport.height,
    deviceScaleFactor: viewport.scale,
    mobile: viewport.mobile
  });
  await cdp.send("Emulation.setTouchEmulationEnabled", {
    enabled: viewport.mobile
  });
  const loaded = cdp.once("Page.loadEventFired");
  await cdp.send("Page.navigate", { url: BOARD_URL });
  await loaded;
  await sleep(8000);
}

/** Evaluates an expression in the page, awaiting a promise, and returns its value. */
export async function evaluate(cdp, expression) {
  const { result, exceptionDetails } = await cdp.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true
  });
  if (exceptionDetails) {
    throw new Error(
      exceptionDetails.exception
        ? exceptionDetails.exception.description
        : exceptionDetails.text
    );
  }
  return result.value;
}

/**
 * Page-side source for `deep(selector)`: every match in the document and in every open shadow
 * root beneath it. The board is LWC, so almost nothing is in the light DOM.
 */
export const DEEP = `
  const deep = (selector) => {
    const found = [];
    const walk = (root) => root.querySelectorAll("*").forEach((node) => {
      if (node.matches(selector)) found.push(node);
      if (node.shadowRoot) walk(node.shadowRoot);
    });
    walk(document);
    return found;
  };`;

/** Page-side: opens a card by clicking its header, the way a visitor does. */
export const openCardScript = (recordNumber) => `(() => {
  ${DEEP}
  const card = deep("c-board-card").find((node) =>
    node.shadowRoot.querySelector("article").dataset.key === ${JSON.stringify(recordNumber)});
  if (!card) return false;
  card.shadowRoot.querySelector("[data-disclosure]").click();
  return true;
})()`;
