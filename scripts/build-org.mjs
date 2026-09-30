/**
 * Builds Portfolio HQ into an org: the app, the Experience Cloud site, the guest's access, the
 * scheduled jobs and, depending on the target, the scratch org's records or a fresh start.
 *
 *   node scripts/build-org.mjs <target>                  plan: stage the build and say what each
 *                                                       stage would do; changes nothing
 *   node scripts/build-org.mjs <target> --validate       check-only deploy of every stage the org
 *                                                       can take today; changes nothing
 *   node scripts/build-org.mjs <target> --deploy         run the build
 *   node scripts/build-org.mjs <target> --deploy --from=<stage>   resume at a stage
 *
 * <target> names build/targets/<target>.json. It says which org, which Jira site, whether to copy
 * the scratch org's records ("copy") or start empty ("fresh"), and optionally a folder of custom
 * metadata rows that replace the repo's for another Jira site or Asana workspace. See
 * docs/deploying-to-an-org.md for the targets, the manual steps before and after, and why each
 * stage is where it is.
 *
 * force-app is never edited. Each deploy stage is staged as its own small SFDX project under
 * build/.out/<target>/<stage>/, with the values that bind metadata to one org - the site admin,
 * the subscriber's running user, the Jira URL, the guest's nickname - rewritten for the target.
 * Every rewrite must match exactly what it expects, or the run stops: a file whose shape changed
 * must not deploy with the scratch org's values still in it.
 *
 * Stages run in this order, because each needs the one before:
 *
 *   core     objects, Apex, components, permission sets, credentials, custom metadata
 *   access   Portfolio_HQ_Developer to the deploying admin (field access, credential grants)
 *   site     the network, both sites and the LWR bundle - needs Digital Experiences enabled
 *   guest    the guest profile and guest sharing rules, then the guest permission sets; the guest
 *            user only exists once the site does
 *   data     copy mode: the scratch org's projects and work items; fresh mode: the target's
 *            projects. Skipped when the target already has either
 *   jobs     the inbound sweeper and the nightly purge, scheduled as the deploying admin
 *   publish  the public site, which serves the bundle it was last published with
 *   tests    RunLocalTests on the target
 *
 * Deploys use NoTestRun, which a Developer Edition or sandbox target allows: the tests run last,
 * once the field access they need has been assigned and the guest user they look for exists.
 */
import { execFileSync, execSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const SOURCE = path.join(ROOT, "force-app", "main", "default");
const SITE_NAME = "Test Professional Site";
const GUEST_PROFILE = "Test Professional Site Profile";
const REST_SITE_PREFIX = "neoGeoTestvforcesite";
const BOARD_SITE_PREFIX = "neoGeoTest";

// ---------- what goes where ----------

/**
 * In source, and not this project's: scratch-org template leftovers and an early exercise. They
 * are kept in the repo as they are; they are not deployed anywhere by this build.
 */
const NEVER = [
  /^appMenus\//,
  /^dashboards\//,
  /^reports\//,
  /^reportTypes\//,
  /^roles\//,
  /^transactionSecurityPolicies\//,
  /^objects\/Account\//,
  /^layouts\/Account-/,
  // Field access comes from Portfolio_HQ_Developer, assigned by the access stage, rather than
  // from overwriting the target's System Administrator profile.
  /^profiles\/Admin\.profile/,
  /^profiles\/B2B Reordering Portal Buyer Profile\./,
  /\/__tests__\//,
  /(^|\/)jsconfig\.json$/,
  /(^|\/)\.eslintrc\.json$/,
  /^customMetadata\/Integration_Secret\./
];

/** Needs Digital Experiences enabled in the target. */
const SITE = [
  /^networks\//,
  /^sites\//,
  /^digitalExperiences\//,
  /^digitalExperienceConfigs\//,
  /^navigationMenus\//,
  /^audience\//,
  /^networkBranding\//
];

/** Needs the site to exist: the guest profile and user are created with it. */
const GUEST = [
  new RegExp(`^profiles/${GUEST_PROFILE}\\.profile-meta\\.xml$`),
  /^sharingRules\//
];

const STAGES = [
  "core",
  "access",
  "site",
  "guest",
  "data",
  "jobs",
  "publish",
  "tests"
];

// ---------- arguments and target ----------

const args = process.argv.slice(2);
const targetName = args.find((arg) => !arg.startsWith("--"));
const mode = args.includes("--deploy")
  ? "deploy"
  : args.includes("--validate")
    ? "validate"
    : "plan";
const fromArg = args.find((arg) => arg.startsWith("--from="));
const from = fromArg ? fromArg.slice("--from=".length) : STAGES[0];

if (!targetName) {
  fail(
    "Name a target: node scripts/build-org.mjs <target> [--validate | --deploy [--from=<stage>]]"
  );
}
if (!STAGES.includes(from)) {
  fail(`--from must be one of ${STAGES.join(", ")}.`);
}
const targetFile = path.join(ROOT, "build", "targets", `${targetName}.json`);
if (!existsSync(targetFile)) {
  fail(`No target file ${path.relative(ROOT, targetFile)}.`);
}
const target = JSON.parse(readFileSync(targetFile, "utf8"));
const OUT = path.join(ROOT, "build", ".out", targetName);

// ---------- helpers ----------

function fail(message) {
  console.error(`\n✖ ${message}`);
  process.exit(1);
}

function heading(text) {
  console.log(`\n── ${text} ${"─".repeat(Math.max(0, 72 - text.length))}`);
}

/** One sf command, JSON out. Throws with the CLI's own message unless allowFail. */
function sf(commandArgs, { cwd = ROOT, allowFail = false } = {}) {
  let out;
  try {
    out = execFileSync("sf", [...commandArgs, "--json"], {
      cwd,
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, SF_AUTOUPDATE_DISABLE: "true" }
    });
  } catch (error) {
    out = error.stdout;
  }
  // The JSON can arrive after other output: the first run of a command whose plugin the CLI
  // installs on demand (community, for one) prints npm's install warnings to stdout first.
  const start = (out || "").search(/^\{/m);
  let parsed;
  try {
    parsed = JSON.parse(start === -1 ? out : out.slice(start));
  } catch {
    throw new Error(`sf ${commandArgs.join(" ")} printed no JSON:\n${out}`);
  }
  if (parsed.status !== 0 && !allowFail) {
    throw new Error(
      `sf ${commandArgs.slice(0, 3).join(" ")} failed: ${parsed.message || JSON.stringify(parsed)}`
    );
  }
  return parsed;
}

function query(org, soql, { allowFail = false } = {}) {
  const result = sf(["data", "query", "--target-org", org, "--query", soql], {
    allowFail
  });
  return result.status === 0 ? result.result.records : null;
}

/** The sf CLI's bundled @salesforce/core, found from the sf binary, as the other scripts do. */
async function connectionTo(org) {
  const sfRoot = path.dirname(
    path.dirname(
      realpathSync(execSync("which sf", { encoding: "utf8" }).trim())
    )
  );
  const require = createRequire(
    path.join(sfRoot, "node_modules/@salesforce/core/package.json")
  );
  const { Org } = require("@salesforce/core");
  const connection = (
    await Org.create({ aliasOrUsername: org })
  ).getConnection();
  await connection.refreshAuth();
  return connection;
}

function filesUnder(dir, base = dir) {
  const files = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) {
      files.push(...filesUnder(full, base));
    } else {
      files.push(path.relative(base, full).split(path.sep).join("/"));
    }
  }
  return files;
}

const matches = (rules, file) => rules.some((rule) => rule.test(file));

function stageOf(file) {
  if (matches(NEVER, file)) {
    return null;
  }
  if (matches(GUEST, file)) {
    return "guest";
  }
  if (matches(SITE, file)) {
    return "site";
  }
  return "core";
}

// ---------- rewrites: the values that bind metadata to one org ----------

const GUEST_PROFILE_FILE = new RegExp(
  `^profiles/${GUEST_PROFILE}\\.profile-meta\\.xml$`
);

/**
 * One whole <tag>...</tag> element containing `inside`, with the line it sits on. The tempered
 * token keeps a match inside a single element rather than spanning from one into the next.
 */
function xmlBlock(tag, inside) {
  const body = `(?:(?!</${tag}>)[\\s\\S])*?`;
  return new RegExp(`\\n[ \\t]*<${tag}>${body}${inside}${body}</${tag}>`, "g");
}

/**
 * Each rewrite names the file it applies to, what it replaces and with what. It must match the
 * expected number of times, or the build stops - the alternative is a file quietly deploying
 * with the scratch org's user in it.
 */
function rewritesFor(context) {
  const list = [
    {
      file: /^sites\/Test_Professional_Site\.site-meta\.xml$/,
      pattern: /<siteAdmin>[^<]*<\/siteAdmin>/g,
      count: 1,
      value: `<siteAdmin>${context.adminUsername}</siteAdmin>`
    },
    {
      file: /^sites\/Test_Professional_Site\.site-meta\.xml$/,
      pattern:
        /<siteGuestRecordDefaultOwner>[^<]*<\/siteGuestRecordDefaultOwner>/g,
      count: 1,
      value: `<siteGuestRecordDefaultOwner>${context.adminUsername}</siteGuestRecordDefaultOwner>`
    },
    {
      // The subscriber must run as a user holding the Asana credential grant; Automated
      // Process cannot be granted it (docs/handoff.md section 3).
      file: /^PlatformEventSubscriberConfigs\/Webhook_Event_Subscriber\./,
      pattern: /<user>[^<]*<\/user>/g,
      count: 1,
      value: `<user>${context.adminUsername}</user>`
    },
    {
      file: /^networks\/Test Professional Site\.network-meta\.xml$/,
      pattern: /<emailSenderAddress>[^<]*<\/emailSenderAddress>/g,
      count: 1,
      value: `<emailSenderAddress>${context.emailSender}</emailSenderAddress>`
    },
    // The guest profile names the early Account customisations this build does not deploy - its
    // fields, record types and layouts - and a profile deploy refuses a name the org lacks. The
    // guest must never reach Account in any case (GuestAccessTest), so the blocks are dropped.
    ...[
      ["fieldPermissions", "<field>Account\\.", 3],
      ["layoutAssignments", "<layout>Account-", 4],
      ["recordTypeVisibilities", "<recordType>Account\\.", 3]
    ].map(([tag, inside, count]) => ({
      file: GUEST_PROFILE_FILE,
      pattern: xmlBlock(tag, inside),
      count,
      value: ""
    }))
  ];
  if (target.jiraBaseUrl) {
    list.push({
      file: /^namedCredentials\/Jira_Classic\.namedCredential-meta\.xml$/,
      pattern:
        /(<parameterName>Url<\/parameterName>\s*<parameterType>Url<\/parameterType>\s*<parameterValue>)[^<]*(<\/parameterValue>)/g,
      count: 1,
      value: `$1${target.jiraBaseUrl}$2`
    });
  }
  if (context.guestNickname) {
    list.push({
      file: /^sharingRules\//,
      pattern: /<guestUser>[^<]*<\/guestUser>/g,
      count: 1,
      value: `<guestUser>${context.guestNickname}</guestUser>`
    });
  }
  return list;
}

/** Custom metadata rows from the target's folder replace every repo row of the same type. */
function customMetadataOverrides() {
  if (!target.customMetadata) {
    return null;
  }
  const dir = path.join(ROOT, target.customMetadata);
  if (!existsSync(dir)) {
    fail(
      `The target's customMetadata folder ${target.customMetadata} does not exist.`
    );
  }
  const files = readdirSync(dir).filter((name) =>
    name.endsWith(".md-meta.xml")
  );
  const types = new Set(files.map((name) => name.split(".")[0]));
  return { dir, files, types };
}

/** Writes one stage's SFDX project. Returns what it staged. */
function stage(stageName, context) {
  const dir = path.join(OUT, stageName);
  rmSync(dir, { recursive: true, force: true });
  const destination = path.join(dir, "force-app", "main", "default");
  mkdirSync(destination, { recursive: true });
  cpSync(
    path.join(ROOT, "sfdx-project.json"),
    path.join(dir, "sfdx-project.json")
  );
  cpSync(path.join(ROOT, ".forceignore"), path.join(dir, ".forceignore"));

  const overrides = customMetadataOverrides();
  const rewrites = rewritesFor(context);
  const staged = [];
  const applied = new Map();

  const place = (relative, text) => {
    const out = path.join(destination, relative);
    mkdirSync(path.dirname(out), { recursive: true });
    writeFileSync(out, text);
    staged.push(relative);
  };

  for (const relative of filesUnder(SOURCE)) {
    if (stageOf(relative) !== stageName) {
      continue;
    }
    if (
      overrides &&
      relative.startsWith("customMetadata/") &&
      overrides.types.has(path.basename(relative).split(".")[0])
    ) {
      continue;
    }
    const sourceFile = path.join(SOURCE, relative);
    const mine = rewrites.filter((rewrite) => rewrite.file.test(relative));
    if (!mine.length) {
      const out = path.join(destination, relative);
      mkdirSync(path.dirname(out), { recursive: true });
      cpSync(sourceFile, out);
      staged.push(relative);
      continue;
    }
    let text = readFileSync(sourceFile, "utf8");
    for (const rewrite of mine) {
      const found = (text.match(rewrite.pattern) || []).length;
      if (found !== rewrite.count) {
        fail(
          `${relative}: expected ${rewrite.count} match of ${rewrite.pattern}, found ${found}. ` +
            "The file changed shape; update the rewrite in scripts/build-org.mjs."
        );
      }
      text = text.replace(rewrite.pattern, rewrite.value);
      applied.set(rewrite, (applied.get(rewrite) || 0) + 1);
    }
    place(relative, text);
  }

  if (overrides && stageName === "core") {
    for (const name of overrides.files) {
      const relative = `customMetadata/${name}`;
      const out = path.join(destination, relative);
      mkdirSync(path.dirname(out), { recursive: true });
      cpSync(path.join(overrides.dir, name), out);
      staged.push(relative);
    }
  }

  // A rewrite whose file is in this stage but never matched means the file moved or was renamed.
  for (const rewrite of rewrites) {
    const wanted = filesUnder(SOURCE).filter(
      (relative) =>
        stageOf(relative) === stageName && rewrite.file.test(relative)
    );
    if (wanted.length && !applied.has(rewrite)) {
      fail(`A rewrite for ${rewrite.file} matched no staged file.`);
    }
  }
  return { dir, staged };
}

function summarise(staged) {
  const byFolder = new Map();
  for (const relative of staged) {
    const folder = relative.split("/")[0];
    byFolder.set(folder, (byFolder.get(folder) || 0) + 1);
  }
  return [...byFolder]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([folder, count]) => `${folder} ${count}`)
    .join(", ");
}

function deploy(stageName, context, { dryRun }) {
  const { dir, staged } = stage(stageName, context);
  console.log(`  ${staged.length} files: ${summarise(staged)}`);
  const result = sf(
    [
      "project",
      "deploy",
      "start",
      "--source-dir",
      "force-app",
      "--target-org",
      target.org,
      "--test-level",
      "NoTestRun",
      "--wait",
      "60",
      ...(dryRun ? ["--dry-run"] : [])
    ],
    { cwd: dir, allowFail: true }
  );
  const body = result.result || result.data || {};
  const failures = [body.details?.componentFailures ?? []].flat();
  if (result.status !== 0 || body.success === false) {
    for (const failure of failures) {
      console.error(
        `  ✖ ${failure.componentType} ${failure.fullName}: ${failure.problem}`
      );
    }
    if (!failures.length) {
      console.error(
        `  ✖ ${result.message || JSON.stringify(body).slice(0, 2000)}`
      );
    }
    fail(
      `The ${stageName} stage did not ${dryRun ? "validate" : "deploy"}. ` +
        `Staged project: ${path.relative(ROOT, dir)}`
    );
  }
  const count = body.numberComponentsDeployed ?? staged.length;
  console.log(
    `  ✔ ${dryRun ? "validated" : "deployed"} (${count} components${body.id ? `, ${body.id}` : ""})`
  );
}

// ---------- org checks ----------

function preflight() {
  heading(`Target ${targetName} → ${target.org} (${mode})`);
  if (target.description) {
    console.log(`  ${target.description}`);
  }
  const display = sf(["org", "display", "--target-org", target.org], {
    allowFail: true
  });
  if (display.status !== 0) {
    fail(`The CLI is not connected to ${target.org}: ${display.message}`);
  }
  const { username, id: orgId, instanceUrl } = display.result;
  if (/\.scratch\./.test(instanceUrl) && target.data?.from === target.org) {
    fail("The target is the org the data would be copied from.");
  }
  const [admin] = query(
    target.org,
    `SELECT Id, Email, TimeZoneSidKey FROM User WHERE Username = '${username}'`
  );
  const digitalExperiences =
    query(target.org, "SELECT COUNT() FROM Network", { allowFail: true }) !==
    null;
  const hasApp =
    query(
      target.org,
      "SELECT Id FROM ApexClass WHERE Name = 'WorkItemSyncService' AND NamespacePrefix = null"
    ).length > 0;

  console.log(`  org        ${instanceUrl} (${orgId})`);
  console.log(`  admin      ${username}, ${admin.TimeZoneSidKey}`);
  console.log(
    `  site       Digital Experiences ${digitalExperiences ? "enabled" : "NOT enabled"}`
  );
  console.log(
    `  app        ${hasApp ? "already deployed once" : "not deployed yet"}`
  );
  console.log(
    `  data       ${target.data?.mode === "copy" ? `copy from ${target.data.from}` : "fresh"}`
  );
  if (target.data?.mode === "copy") {
    const source = sf(["org", "display", "--target-org", target.data.from], {
      allowFail: true
    });
    if (source.status !== 0) {
      fail(`Cannot reach ${target.data.from} to copy from: ${source.message}`);
    }
  }
  if (target.customMetadata) {
    const overrides = customMetadataOverrides();
    console.log(
      `  metadata   ${overrides.files.length} rows from ${target.customMetadata} replace the repo's ${[...overrides.types].join(", ")} rows`
    );
  }
  return {
    adminUsername: username,
    adminId: admin.Id,
    emailSender: target.siteEmailSender || admin.Email,
    orgId,
    instanceUrl,
    digitalExperiences,
    guestNickname: null
  };
}

function guestUser() {
  const [guest] =
    query(
      target.org,
      `SELECT Id, Username, CommunityNickname FROM User WHERE UserType = 'Guest' AND Profile.Name = '${GUEST_PROFILE}'`,
      { allowFail: true }
    ) || [];
  return guest || null;
}

function assign(permissionSet, userId, username) {
  const held = query(
    target.org,
    `SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = '${userId}' AND PermissionSet.Name = '${permissionSet}'`
  );
  if (held.length) {
    console.log(`  · ${permissionSet} already assigned to ${username}`);
    return;
  }
  sf([
    "org",
    "assign",
    "permset",
    "--name",
    permissionSet,
    "--on-behalf-of",
    username,
    "--target-org",
    target.org
  ]);
  console.log(`  ✔ ${permissionSet} → ${username}`);
}

// ---------- data ----------

const PROJECT_FIELDS = [
  "Name",
  "External_Project_Key__c",
  "External_System__c",
  "GitHub_URL__c",
  "Is_Public__c",
  "Short_Name__c",
  "Status__c"
];

// Everything a work item carries except its owner (the target's admin owns the copy), its
// assignee (a user of the other org), its lookups (mapped below) and any sync work in flight
// (none is copied: a pending push belongs to the org that staged it).
const WORK_ITEM_FIELDS = [
  "Title__c",
  "Description__c",
  "External_Id__c",
  "External_Key__c",
  "External_System__c",
  "External_URL__c",
  "Is_Public__c",
  "Last_Synced__c",
  "Remote_Last_Modified__c",
  "Status__c",
  "Story_Points__c",
  "Sync_Status__c",
  "Type__c",
  "Source_Type__c",
  "Due_Date__c",
  "Source_Created__c",
  "Start_Date__c",
  "Priority__c"
];

async function insertAll(connection, sobject, records) {
  const ids = [];
  for (let i = 0; i < records.length; i += 200) {
    const results = await connection
      .sobject(sobject)
      .create(records.slice(i, i + 200), { allOrNone: true });
    for (const result of [results].flat()) {
      if (!result.success) {
        throw new Error(
          `${sobject} insert failed: ${JSON.stringify(result.errors)}`
        );
      }
      ids.push(result.id);
    }
  }
  return ids;
}

async function data(context) {
  const connection = await connectionTo(target.org);
  const existing = await connection.query(
    "SELECT COUNT(Id) n FROM Work_Item__c"
  );
  const projects = await connection.query("SELECT COUNT(Id) n FROM Project__c");
  const held = existing.records[0].n + projects.records[0].n;
  if (held) {
    console.log(
      `  · the target already holds ${projects.records[0].n} projects and ${existing.records[0].n} work items; nothing is imported over them`
    );
    return;
  }

  if (target.data?.mode === "fresh") {
    const rows = (target.data.projects || []).map((project) => ({
      Name: project.name,
      Short_Name__c: project.shortName,
      External_System__c: project.system,
      External_Project_Key__c: project.key,
      Is_Public__c: project.public === true
    }));
    if (rows.some((row) => /^</.test(row.External_Project_Key__c || ""))) {
      fail(
        "The target's projects still hold <placeholders>. Fill them in first."
      );
    }
    await insertAll(connection, "Project__c", rows);
    console.log(
      `  ✔ ${rows.length} projects created; work items arrive by webhook delivery`
    );
    return;
  }

  const source = await connectionTo(target.data.from);
  const sourceProjects = (
    await source.query(
      `SELECT Id, ${PROJECT_FIELDS.join(", ")} FROM Project__c ORDER BY Name`,
      { autoFetch: true, maxFetch: 50000 }
    )
  ).records;
  const sourceItems = (
    await source.query(
      `SELECT Id, Name, Project__c, Parent_Work_Item__c, ${WORK_ITEM_FIELDS.join(", ")} FROM Work_Item__c ORDER BY Name`,
      { autoFetch: true, maxFetch: 50000 }
    )
  ).records;

  const pick = (record, fields) =>
    Object.fromEntries(fields.map((field) => [field, record[field] ?? null]));

  const projectIds = await insertAll(
    connection,
    "Project__c",
    sourceProjects.map((project) => pick(project, PROJECT_FIELDS))
  );
  const projectMap = new Map(
    sourceProjects.map((project, i) => [project.Id, projectIds[i]])
  );

  // Inserted in record-number order, so WI-0000 in one org is the first number in the other.
  // An insert never pushes: WorkItemTrigger pushes on update only.
  const itemIds = await insertAll(
    connection,
    "Work_Item__c",
    sourceItems.map((item) => ({
      ...pick(item, WORK_ITEM_FIELDS),
      Project__c: item.Project__c ? projectMap.get(item.Project__c) : null
    }))
  );
  const itemMap = new Map(sourceItems.map((item, i) => [item.Id, itemIds[i]]));

  // Parents second, once every record exists. Parent_Work_Item__c is not a pushable field, so
  // this update stages nothing and queues nothing.
  const links = sourceItems
    .filter(
      (item) =>
        item.Parent_Work_Item__c && itemMap.has(item.Parent_Work_Item__c)
    )
    .map((item) => ({
      Id: itemMap.get(item.Id),
      Parent_Work_Item__c: itemMap.get(item.Parent_Work_Item__c)
    }));
  for (let i = 0; i < links.length; i += 200) {
    const results = await connection
      .sobject("Work_Item__c")
      .update(links.slice(i, i + 200), { allOrNone: true });
    for (const result of [results].flat()) {
      if (!result.success) {
        throw new Error(`Parent link failed: ${JSON.stringify(result.errors)}`);
      }
    }
  }

  const renumbered = (
    await connection.query(
      `SELECT Id, Name FROM Work_Item__c WHERE Id IN ('${itemIds.join("','")}')`
    )
  ).records;
  const nameById = new Map(
    renumbered.map((record) => [record.Id, record.Name])
  );
  const moved = sourceItems.filter(
    (item) => nameById.get(itemMap.get(item.Id)) !== item.Name
  );
  console.log(
    `  ✔ ${projectIds.length} projects, ${itemIds.length} work items, ${links.length} parent links`
  );
  if (moved.length) {
    console.log(
      `  · record numbers changed: ${moved
        .map((item) => `${item.Name}→${nameById.get(itemMap.get(item.Id))}`)
        .join(", ")}`
    );
  }

  // The featured epic is org data. Carried across when one is set, mapped to its new id.
  const setting = (
    await source.query("SELECT SetupOwnerId, Epic_Id__c FROM Featured_Epic__c")
  ).records.find((row) => row.SetupOwnerId?.startsWith("00D"));
  const featured = setting?.Epic_Id__c
    ? [...itemMap].find(
        ([oldId]) => oldId.slice(0, 15) === setting.Epic_Id__c.slice(0, 15)
      )
    : null;
  if (featured) {
    await connection
      .sobject("Featured_Epic__c")
      .create({ SetupOwnerId: context.orgId, Epic_Id__c: featured[1] });
    console.log(
      `  ✔ featured epic carried across: ${nameById.get(featured[1])}`
    );
  } else {
    console.log("  · no epic featured in the source; none featured here");
  }
}

// ---------- the other stages ----------

function jobs() {
  for (const script of [
    "scripts/apex/schedule-inbound-sweeper.apex",
    "scripts/apex/schedule-data-purge.apex"
  ]) {
    const result = sf([
      "apex",
      "run",
      "--file",
      script,
      "--target-org",
      target.org
    ]);
    if (!result.result.success) {
      fail(
        `${script} failed: ${result.result.compileProblem || result.result.exceptionMessage}`
      );
    }
    console.log(`  ✔ ${path.basename(script, ".apex")}`);
  }
}

function publish() {
  const result = sf([
    "community",
    "publish",
    "--name",
    SITE_NAME,
    "--target-org",
    target.org
  ]);
  console.log(
    `  ✔ publish queued (${result.result.jobId || "job"}); it goes live a minute or so later`
  );
}

function tests() {
  const result = sf(
    [
      "apex",
      "run",
      "test",
      "--target-org",
      target.org,
      "--test-level",
      "RunLocalTests",
      "--wait",
      "120"
    ],
    { allowFail: true }
  );
  const summary = result.result?.summary;
  if (!summary) {
    fail(`The test run did not report: ${result.message}`);
  }
  console.log(
    `  ${summary.outcome}: ${summary.passing} passed, ${summary.failing} failed of ${summary.testsRan} (the summary counts each @TestSetup as a test)`
  );
  for (const test of result.result.tests || []) {
    if (test.Outcome !== "Pass") {
      console.log(`  ✖ ${test.FullName}: ${test.Message}`);
    }
  }
}

function checklist(context) {
  const [domain] =
    query(
      target.org,
      "SELECT Domain FROM Domain WHERE Domain LIKE '%.my.site.com'",
      { allowFail: true }
    ) || [];
  const site = domain ? `https://${domain.Domain}` : "https://<site domain>";
  const asanaProjects = (
    query(
      target.org,
      "SELECT External_Project_Key__c FROM Project__c WHERE External_System__c = 'Asana' AND External_Project_Key__c != null",
      { allowFail: true }
    ) || []
  ).map((row) => row.External_Project_Key__c);
  const lines = [
    `# After the build: ${targetName} (${target.org})`,
    "",
    "Generated by scripts/build-org.mjs. None of this is metadata; see docs/deploying-to-an-org.md.",
    "",
    "1. Jira token: Setup > Named Credentials > External Credentials > Jira_Token > principal",
    "   **Personal Key** > Authentication Parameters: username = the Atlassian account email,",
    "   password = an API token.",
    "2. Asana token: External Credentials > Asana_Token > principal **PAT1** > Token = a personal",
    "   access token.",
    `3. Jira webhook: in Jira, a webhook to ${site}/${REST_SITE_PREFIX}/services/apexrest/v1/webhook/jira`,
    "   (event Issue > updated, JQL for your project, a secret set). Then Setup > Custom Metadata",
    "   Types > Integration Secret > New: DeveloperName **Jira_Webhook**, the same secret, Active.",
    "4. Asana webhook, per tracked project - the handshake stages the secret:",
    ...(asanaProjects.length ? asanaProjects : ["<project gid>"]).map(
      (gid) =>
        `   curl -X POST https://app.asana.com/api/1.0/webhooks -H "Authorization: Bearer $ASANA_PAT" -H "Content-Type: application/json" -d '{"data":{"resource":"${gid}","target":"${site}/${REST_SITE_PREFIX}/services/apexrest/v1/webhook/asana/${gid}"}}'`
    ),
    `   then: sf apex run --file scripts/apex/promote-webhook-secret.apex --target-org ${target.org}`,
    "   and delete the staged Webhook_Secret__c row once the promotion has deployed.",
    "5. Change one Jira status on the internal board and watch Integration_Log__c gain 3 rows;",
    "   change one in Jira and watch the delivery reach Processed. If deliveries stay Pending,",
    "   suspend and resume Setup > Platform Events > Webhook Event Received > Subscriptions.",
    `6. The public board, logged out: ${site}/${BOARD_SITE_PREFIX}/work-item-board`,
    ...(target.data?.mode === "copy"
      ? [
          `7. ${target.data.from}'s webhooks still point at ${target.data.from}. Disable the Jira one and`,
          "   let Asana's lapse, or both orgs keep receiving until the scratch org expires."
        ]
      : [])
  ];
  const file = path.join(OUT, "checklist.md");
  mkdirSync(OUT, { recursive: true });
  writeFileSync(file, `${lines.join("\n")}\n`);
  console.log(
    lines
      .slice(4)
      .map((line) => `  ${line}`)
      .join("\n")
  );
  console.log(`\n  Written to ${path.relative(ROOT, file)}`);
}

// ---------- run ----------

const context = preflight();
const runs = (name) => STAGES.indexOf(name) >= STAGES.indexOf(from);

if (mode === "plan") {
  for (const name of ["core", "site", "guest"]) {
    heading(`${name} (staged, not deployed)`);
    const { staged, dir } = stage(name, context);
    console.log(`  ${staged.length} files: ${summarise(staged)}`);
    console.log(`  → ${path.relative(ROOT, dir)}`);
  }
  heading("then, with --deploy");
  console.log(
    "  access   Portfolio_HQ_Developer → the admin\n" +
      "  guest    guest nickname substituted into the sharing rules; guest permission sets assigned\n" +
      `  data     ${target.data?.mode === "copy" ? `copy projects and work items from ${target.data.from}` : "create the target's projects"}; skipped if any exist\n` +
      "  jobs     sweeper (4 schedules) and nightly purge, as the admin\n" +
      `  publish  ${SITE_NAME}\n` +
      "  tests    RunLocalTests"
  );
  if (!context.digitalExperiences) {
    console.log(
      "\n  Before --deploy: enable Digital Experiences in the target (docs/deploying-to-an-org.md)."
    );
  }
  process.exit(0);
}

if (mode === "validate") {
  heading("core (check only)");
  deploy("core", context, { dryRun: true });
  heading("site (check only)");
  if (context.digitalExperiences) {
    console.log(
      "  · the site validates only after core is deployed: it names pages and classes that core creates"
    );
  } else {
    console.log(
      "  · skipped: Digital Experiences is not enabled in the target"
    );
  }
  heading("guest");
  console.log(
    "  · validates only once the site exists: the guest profile and user come with it"
  );
  process.exit(0);
}

if (!context.digitalExperiences) {
  fail(
    "Digital Experiences is not enabled in the target. Enable it first (docs/deploying-to-an-org.md), then rerun."
  );
}

if (runs("core")) {
  heading("core");
  deploy("core", context, { dryRun: false });
}
if (runs("access")) {
  heading("access");
  assign("Portfolio_HQ_Developer", context.adminId, context.adminUsername);
}
if (runs("site")) {
  heading("site");
  deploy("site", context, { dryRun: false });
}
if (runs("guest")) {
  heading("guest");
  const guest = guestUser();
  if (!guest) {
    fail(
      `No guest user with profile "${GUEST_PROFILE}". The site deploy should have created it; check Setup > Digital Experiences > All Sites.`
    );
  }
  console.log(
    `  guest      ${guest.Username} (nickname ${guest.CommunityNickname})`
  );
  context.guestNickname = guest.CommunityNickname;
  deploy("guest", context, { dryRun: false });
  assign("Jira_Webhook_Guest", guest.Id, guest.Username);
  assign("Portfolio_HQ_Guest", guest.Id, guest.Username);
}
if (runs("data")) {
  heading(`data (${target.data?.mode || "none"})`);
  await data(context);
}
if (runs("jobs")) {
  heading("jobs");
  jobs();
}
if (runs("publish")) {
  heading("publish");
  publish();
}
if (runs("tests")) {
  heading("tests");
  tests();
}
heading("what the build cannot do");
checklist(context);
