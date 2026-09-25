/**
 * Print the Change Data Capture events the internal board would receive, from the command line.
 *
 *   node scripts/listen-work-item-changes.mjs [seconds=90] [events=1] [ready-file]
 *
 * Subscribes to /data/Work_Item__ChangeEvent - the channel workItemBoard subscribes to through
 * lightning/empApi - and prints each event's change type, record ids, changedFields and body,
 * until it has seen the number of events asked for or the time is up. Make the change in another
 * terminal once it prints "subscribed". With a ready-file, it also writes that file at that
 * moment, so a script can wait for it.
 *
 * Why this exists: whether a field reaches the board live is a property of the event, and the
 * board shows only what it renders. Build 09 step 1 used it to confirm Priority__c travels in the
 * event, set and cleared, before anything rendered a priority.
 *
 * Runs as the CLI's default user for MyScratchOrg, which needs View All Records on Work_Item__c or
 * View All Data (see docs/handoff.md) - the same rule the board is under. The session comes from
 * the CLI's own library, refreshed first: the token `sf org display` prints can be stale, and a
 * stale one fails the handshake with "401::Request requires authentication". Never prints it.
 */
import { execSync } from "node:child_process";
import { realpathSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const [seconds = "90", wanted = "1", readyFile] = process.argv.slice(2);

// The sf CLI's bundled @salesforce/core, found from the sf binary rather than a hardcoded path.
const sfRoot = path.dirname(
  path.dirname(realpathSync(execSync("which sf", { encoding: "utf8" }).trim()))
);
const require = createRequire(
  path.join(sfRoot, "node_modules/@salesforce/core/package.json")
);
const { Org } = require("@salesforce/core");

const connection = (
  await Org.create({ aliasOrUsername: "MyScratchOrg" })
).getConnection();
await connection.refreshAuth();
const endpoint = `${connection.instanceUrl}/cometd/${connection.getApiVersion()}`;
const channel = "/data/Work_Item__ChangeEvent";
const cookies = {};

// One Bayeux round trip. The server pins a client to a node with cookies, so they are kept.
async function post(messages) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${connection.accessToken}`,
      "Content-Type": "application/json",
      Cookie: Object.entries(cookies)
        .map(([name, value]) => `${name}=${value}`)
        .join("; ")
    },
    body: JSON.stringify(messages)
  });
  for (const header of response.headers.getSetCookie()) {
    const [pair] = header.split(";");
    const at = pair.indexOf("=");
    cookies[pair.slice(0, at)] = pair.slice(at + 1);
  }
  return response.json();
}

const [handshake] = await post([
  {
    channel: "/meta/handshake",
    version: "1.0",
    supportedConnectionTypes: ["long-polling"]
  }
]);
if (!handshake.successful) {
  throw new Error(`Handshake refused: ${JSON.stringify(handshake)}`);
}
const clientId = handshake.clientId;
const [subscribed] = await post([
  { channel: "/meta/subscribe", clientId, subscription: channel }
]);
if (!subscribed.successful) {
  throw new Error(`Subscription refused: ${JSON.stringify(subscribed)}`);
}
await post([
  { channel: "/meta/connect", clientId, connectionType: "long-polling" }
]);
console.log(`subscribed to ${channel}`);
if (readyFile) {
  writeFileSync(readyFile, "subscribed");
}

const deadline = Date.now() + Number(seconds) * 1000;
let seen = 0;
while (Date.now() < deadline && seen < Number(wanted)) {
  const messages = await post([
    { channel: "/meta/connect", clientId, connectionType: "long-polling" }
  ]);
  for (const message of messages) {
    if (message.channel !== channel) {
      continue;
    }
    seen++;
    const { ChangeEventHeader: header, ...body } = message.data.payload;
    console.log(
      `event ${seen}: ${header.changeType} ${header.recordIds.join(",")} ` +
        `changedFields=${JSON.stringify(header.changedFields)} body=${JSON.stringify(body)}`
    );
  }
}
await post([{ channel: "/meta/disconnect", clientId }]);
console.log(`done: ${seen} event(s)`);
