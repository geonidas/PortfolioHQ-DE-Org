/**
 * Screenshots of the public board as an anonymous visitor sees it: a fresh browser profile, no
 * session, at a desktop width and at a 375px phone in portrait.
 *
 *   node scripts/capture-public-board.mjs <out-dir> <label>
 *
 * Writes <label>-public-desktop.png and <label>-public-375.png. Drives headless Chrome over the
 * DevTools protocol rather than with --screenshot, because headless Chrome will not size a window
 * below about 500px - a "375px" capture that way is a 500px page cropped. Device emulation sets
 * the viewport itself, and marks it a touch phone.
 *
 * Reads nothing from the org and signs in to nothing: what it captures is what the guest gets.
 */
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const URL =
  "https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board";
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9333;
const VIEWPORTS = [
  { name: "desktop", width: 1440, height: 1000, scale: 1, mobile: false },
  { name: "375", width: 375, height: 812, scale: 2, mobile: true }
];

const [outDir = ".", label = "capture"] = process.argv.slice(2);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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
  return new Promise((resolve) =>
    socket.addEventListener("open", () =>
      resolve({ send, once, close: () => socket.close() })
    )
  );
}

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
  for (const viewport of VIEWPORTS) {
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
    await cdp.send("Page.navigate", { url: URL });
    await loaded;
    // The board renders after the page loads: the site boots, then the wire returns.
    await sleep(8000);
    const { data } = await cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: true
    });
    const file = path.join(outDir, `${label}-public-${viewport.name}.png`);
    writeFileSync(file, Buffer.from(data, "base64"));
    console.log(file);
  }
  cdp.close();
} finally {
  // Chrome keeps writing to its profile until it has exited.
  const exited = new Promise((resolve) => chrome.once("exit", resolve));
  chrome.kill();
  await exited;
  rmSync(profile, { recursive: true, force: true, maxRetries: 5 });
}
