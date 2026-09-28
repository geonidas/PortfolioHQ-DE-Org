/**
 * Screenshots of the public board as an anonymous visitor sees it, at a desktop width and at a
 * 375px phone in portrait.
 *
 *   node scripts/capture-public-board.mjs <out-dir> <label> [record number to open]
 *
 * Writes <label>-public-desktop.png and <label>-public-375.png. With a record number, that card
 * is opened first, the way a visitor opens it: by clicking its header. See lib/guest-browser.mjs
 * for why this drives headless Chrome over the DevTools protocol.
 *
 * Reads nothing from the org and signs in to nothing: what it captures is what the guest gets.
 */
import { writeFileSync } from "node:fs";
import path from "node:path";
import {
  VIEWPORTS,
  evaluate,
  loadBoard,
  openCardScript,
  sleep,
  withGuestBrowser
} from "./lib/guest-browser.mjs";

const [outDir = ".", label = "capture", openRecord] = process.argv.slice(2);

await withGuestBrowser(async (cdp) => {
  for (const viewport of VIEWPORTS) {
    await loadBoard(cdp, viewport);
    if (openRecord) {
      if (!(await evaluate(cdp, openCardScript(openRecord)))) {
        throw new Error(`No card ${openRecord} on the public board`);
      }
      await sleep(500);
    }
    const { data } = await cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: true
    });
    const file = path.join(outDir, `${label}-public-${viewport.name}.png`);
    writeFileSync(file, Buffer.from(data, "base64"));
    console.log(file);
  }
});
