/**
 * The code tour: docs/tour/NN-*.md are the source, and this keeps them, their index and the
 * CodeTour files in .tours/ in step with the code they point at.
 *
 *   node scripts/code-tour.mjs           refresh every line link, table of contents and index,
 *                                        and regenerate .tours/
 *   node scripts/code-tour.mjs --check   change nothing; exit 1 if any of that is out of date
 *
 * A stop names its place in the code by a snippet that must occur exactly once in the file:
 *
 *   <!-- at: force-app/main/default/triggers/WorkItemTrigger.trigger | trigger WorkItemTrigger on -->
 *
 * The line after that marker is generated: a link to the line the snippet is on, which GitHub
 * opens at that line. The .tour file carries the snippet as the step's pattern, so the CodeTour
 * extension finds the line the same way after the file has moved on. A snippet that matches
 * nothing, or matches twice, fails the run rather than pointing a reader at the wrong line.
 *
 * Every "**Pattern: Name.**" in a stop must be defined in the list after the
 * "<!-- patterns:define -->" marker, and every name defined there must be used somewhere, so a
 * misspelt name fails the run instead of quietly forking the index in docs/tour/README.md.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  unlinkSync,
  writeFileSync
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as prettier from "prettier";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const TOUR_DIR = path.join(ROOT, "docs", "tour");
const CODETOUR_DIR = path.join(ROOT, ".tours");
const INDEX = path.join(TOUR_DIR, "README.md");

const TOUR_FILE = /^(\d{2})-[a-z0-9-]+\.md$/;
const AT = /^<!-- at: (.+?) \| (.+) -->$/;
const GENERATED_LINK = /^\[[^\]]+:\d+\]\([^)]+#L\d+\)$/;
const STOP_HEADING = /^## (?:\d+\. )?(.+)$/;
const PATTERN_USE = /\*\*Pattern: (.+?)\.\*\*/g;
const DEFINE_MARKER = "<!-- patterns:define -->";
const DEFINITION = /^- \*\*(.+?)\.\*\* (.+)$/;
const GROUP = /^\*\*(.+)\*\*$/;

const check = process.argv.includes("--check");
const problems = [];

/** GitHub's heading anchor: lowercased, punctuation dropped, each space a hyphen. */
function slug(heading) {
  return heading
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, "")
    .replace(/\s/g, "-");
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Lines between two marker comments, exclusive, or null when the markers are absent. */
function between(lines, start, end) {
  const from = lines.indexOf(start);
  const to = lines.indexOf(end);
  return from === -1 || to === -1 || to < from ? null : { from, to };
}

/** Where a snippet sits: its line number, when it occurs exactly once in the file. */
function locate(file, snippet, where) {
  const absolute = path.join(ROOT, file);
  if (!existsSync(absolute)) {
    problems.push(`${where}: ${file} does not exist.`);
    return null;
  }
  const text = readFileSync(absolute, "utf8");
  const first = text.indexOf(snippet);
  if (first === -1) {
    problems.push(`${where}: "${snippet}" is not in ${file}.`);
    return null;
  }
  if (text.indexOf(snippet, first + 1) !== -1) {
    problems.push(
      `${where}: "${snippet}" occurs more than once in ${file}. Lengthen it.`
    );
    return null;
  }
  return text.slice(0, first).split("\n").length;
}

function parseTour(fileName) {
  const number = Number(TOUR_FILE.exec(fileName)[1]);
  const lines = readFileSync(path.join(TOUR_DIR, fileName), "utf8").split("\n");
  const title = lines[0].replace(/^# /, "").trim();
  const toc = between(lines, "<!-- stops:start -->", "<!-- stops:end -->");
  if (!toc) {
    throw new Error(`${fileName} has no <!-- stops:start/end --> markers.`);
  }
  const intro = lines.slice(1, toc.from).join("\n").trim();
  const nav = between(lines, "<!-- nav:start -->", "<!-- nav:end -->");
  const bodyLines = lines.slice(toc.to + 1, nav ? nav.from : lines.length);

  const stops = [];
  for (const line of bodyLines) {
    const heading = STOP_HEADING.exec(line);
    if (heading) {
      stops.push({ title: heading[1].trim(), lines: [] });
    } else if (stops.length) {
      stops.at(-1).lines.push(line);
    }
  }

  stops.forEach((stop, index) => {
    stop.number = index + 1;
    stop.where = `${fileName} stop ${stop.number}`;
    const content = [...stop.lines];
    const marker = content.findIndex((line) => AT.test(line));
    if (marker !== -1) {
      const [, file, snippet] = AT.exec(content[marker]);
      stop.at = { file: file.trim(), snippet: snippet.trim() };
      stop.line = locate(stop.at.file, stop.at.snippet, stop.where);
      // The marker, and the link this script wrote under it last time, which Prettier separates
      // from it with a blank line.
      let end = marker + 1;
      while (end < content.length && content[end].trim() === "") {
        end++;
      }
      if (GENERATED_LINK.test(content[end] || "")) {
        content.splice(marker, end - marker + 1);
      } else {
        content.splice(marker, 1);
      }
    }
    stop.body = content.join("\n").trim();
    stop.heading = `${stop.number}. ${stop.title}`;
    stop.anchor = slug(stop.heading);
    delete stop.lines;
  });

  return { number, fileName, title, intro, stops };
}

function linkTo(stop) {
  const absolute = path.join(ROOT, stop.at.file);
  const relative = path.relative(TOUR_DIR, absolute).split(path.sep).join("/");
  return `[${path.basename(absolute)}:${stop.line}](${relative}#L${stop.line})`;
}

function codeTourTitle(tour) {
  return `${tour.number} · ${tour.title}`;
}

function renderTour(tour, previous, next) {
  const out = [`# ${tour.title}`, "", tour.intro, "", "<!-- stops:start -->"];
  out.push("");
  tour.stops.forEach((stop) =>
    out.push(`${stop.number}. [${stop.title}](#${stop.anchor})`)
  );
  out.push("", "<!-- stops:end -->", "");
  for (const stop of tour.stops) {
    out.push(`## ${stop.heading}`, "");
    if (stop.at) {
      out.push(`<!-- at: ${stop.at.file} | ${stop.at.snippet} -->`, "");
      out.push(linkTo(stop), "");
    }
    out.push(stop.body, "");
  }
  const links = [];
  if (previous) {
    links.push(`[← ${codeTourTitle(previous)}](${previous.fileName})`);
  }
  links.push("[All tours](README.md)");
  if (next) {
    links.push(`[${codeTourTitle(next)} →](${next.fileName})`);
  }
  out.push("<!-- nav:start -->", "", "---", "", links.join(" · "), "");
  out.push("<!-- nav:end -->", "");
  return out.join("\n");
}

/** A step's words for the CodeTour panel: the stop without the markers this script owns. */
function stepDescription(body) {
  return body
    .split("\n")
    .filter((line) => line.trim() !== DEFINE_MARKER)
    .join("\n")
    .trim();
}

function renderCodeTour(tour, next) {
  const codeTour = {
    $schema: "https://aka.ms/codetour-schema",
    title: codeTourTitle(tour),
    description: tour.intro
  };
  if (tour.number === 1) {
    codeTour.isPrimary = true;
  }
  if (next) {
    codeTour.nextTour = codeTourTitle(next);
  }
  codeTour.steps = tour.stops.map((stop) =>
    stop.at
      ? {
          file: stop.at.file,
          pattern: escapeRegExp(stop.at.snippet),
          title: stop.title,
          description: stepDescription(stop.body)
        }
      : { title: stop.title, description: stepDescription(stop.body) }
  );
  return `${JSON.stringify(codeTour, null, 2)}\n`;
}

/** The pattern definitions, in order and by group, from the stop that carries the marker. */
function definitionsFrom(tours) {
  const definitions = [];
  for (const tour of tours) {
    for (const stop of tour.stops) {
      const lines = stop.body.split("\n");
      const marker = lines.indexOf(DEFINE_MARKER);
      if (marker === -1) {
        continue;
      }
      let group = "Patterns";
      for (const line of lines.slice(marker + 1)) {
        const heading = GROUP.exec(line.trim());
        const definition = DEFINITION.exec(line.trim());
        if (definition) {
          definitions.push({ name: definition[1], rule: definition[2], group });
        } else if (heading) {
          group = heading[1];
        }
      }
    }
  }
  return definitions;
}

function patternUses(tours) {
  const uses = new Map();
  for (const tour of tours) {
    for (const stop of tour.stops) {
      for (const match of stop.body.matchAll(PATTERN_USE)) {
        if (!uses.has(match[1])) {
          uses.set(match[1], []);
        }
        uses.get(match[1]).push({ tour, stop });
      }
    }
  }
  return uses;
}

function renderIndex(tours) {
  const lines = readFileSync(INDEX, "utf8").split("\n");
  const toursAt = between(lines, "<!-- tours:start -->", "<!-- tours:end -->");
  const patternsAt = between(
    lines,
    "<!-- patterns:start -->",
    "<!-- patterns:end -->"
  );
  if (!toursAt || !patternsAt || patternsAt.from < toursAt.to) {
    throw new Error(
      "docs/tour/README.md needs <!-- tours:start/end --> then <!-- patterns:start/end -->."
    );
  }

  const tourList = [""];
  for (const tour of tours) {
    const summary = tour.intro.split("\n\n")[0].replace(/\s+/g, " ");
    tourList.push(
      `${tour.number}. **[${tour.title}](${tour.fileName})** (${tour.stops.length} stops). ${summary}`
    );
  }
  tourList.push("");

  const definitions = definitionsFrom(tours);
  const uses = patternUses(tours);
  const defined = new Set(definitions.map((d) => d.name));
  for (const [name, where] of uses) {
    if (!defined.has(name)) {
      const at = where.map((u) => `${u.tour.number}.${u.stop.number}`);
      problems.push(
        `Pattern "${name}" (at ${at.join(", ")}) is not in the definitions.`
      );
    }
  }
  const patternList = [""];
  let group = null;
  for (const definition of definitions) {
    const where = uses.get(definition.name) || [];
    if (!where.length) {
      problems.push(`Pattern "${definition.name}" is defined but never used.`);
    }
    if (definition.group !== group) {
      group = definition.group;
      patternList.push(`### ${group}`, "");
    }
    patternList.push(`- **${definition.name}.** ${definition.rule}`);
    for (const { tour, stop } of where) {
      patternList.push(
        `  - [${tour.number}.${stop.number} ${stop.title}](${tour.fileName}#${stop.anchor})`
      );
    }
    patternList.push("");
  }

  return [
    ...lines.slice(0, toursAt.from + 1),
    ...tourList,
    ...lines.slice(toursAt.to, patternsAt.from + 1),
    ...patternList,
    ...lines.slice(patternsAt.to)
  ].join("\n");
}

async function formatted(text, file) {
  const options = (await prettier.resolveConfig(file)) ?? {};
  return prettier.format(text, { ...options, filepath: file });
}

const tourFiles = readdirSync(TOUR_DIR)
  .filter((name) => TOUR_FILE.test(name))
  .sort();
const tours = tourFiles.map(parseTour);

const outputs = new Map();
for (const [index, tour] of tours.entries()) {
  const previous = tours[index - 1];
  const next = tours[index + 1];
  const markdown = path.join(TOUR_DIR, tour.fileName);
  outputs.set(
    markdown,
    await formatted(renderTour(tour, previous, next), markdown)
  );
  outputs.set(
    path.join(CODETOUR_DIR, tour.fileName.replace(/\.md$/, ".tour")),
    renderCodeTour(tour, next)
  );
}
outputs.set(INDEX, await formatted(renderIndex(tours), INDEX));

const stale = existsSync(CODETOUR_DIR)
  ? readdirSync(CODETOUR_DIR)
      .filter((name) => name.endsWith(".tour"))
      .map((name) => path.join(CODETOUR_DIR, name))
      .filter((file) => !outputs.has(file))
  : [];

if (problems.length) {
  console.error(problems.map((problem) => `  ${problem}`).join("\n"));
  console.error(`\n${problems.length} problem(s). Nothing was written.`);
  process.exit(1);
}

const changed = [...outputs].filter(
  ([file, text]) => !existsSync(file) || readFileSync(file, "utf8") !== text
);
const relative = (file) => path.relative(ROOT, file);

if (check) {
  if (changed.length || stale.length) {
    changed.forEach(([file]) =>
      console.error(`  out of date: ${relative(file)}`)
    );
    stale.forEach((file) => console.error(`  no source:   ${relative(file)}`));
    console.error("\nRun: npm run tour");
    process.exit(1);
  }
  const stops = tours.reduce((sum, tour) => sum + tour.stops.length, 0);
  console.log(
    `Code tour current: ${tours.length} tours, ${stops} stops, every snippet found once.`
  );
} else {
  mkdirSync(CODETOUR_DIR, { recursive: true });
  changed.forEach(([file, text]) => {
    writeFileSync(file, text);
    console.log(`  wrote ${relative(file)}`);
  });
  stale.forEach((file) => {
    unlinkSync(file);
    console.log(`  removed ${relative(file)}`);
  });
  if (!changed.length && !stale.length) {
    console.log("Code tour already current.");
  }
}
