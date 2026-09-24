/**
 * What a card says, shared by both boards: its heading, its identifiers, its dates, its sync
 * state, and which cards a filter keeps.
 *
 * Imports nothing, like boardLayout beside it, and for the same reason: the public board imports
 * this module, so anything it imported would reach an anonymous visitor's bundle. Both boards'
 * payloads use the same property names for the same facts (build 08 step 5), so every function
 * here reads either one. Pure: no wire, no state, no DOM.
 *
 * Vendor-neutral. A card's source arrives as a label to render and an accent token to paint;
 * nothing here compares either to a name.
 */
export const VIEW_TASKS = "tasks";
export const VIEW_EPICS = "epics";
export const VIEW_OPTIONS = [
  { value: VIEW_TASKS, label: "Tasks" },
  { value: VIEW_EPICS, label: "Epics" }
];
/** The Source filter's value for "no filter". An empty string, so it never equals a label. */
export const ALL_SOURCES = "";

const DONE = "Done";
const PENDING = "Pending";
const FAILED = "Failed";
const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec"
];
const ISO_DAY = /^(\d{4})-(\d{2})-(\d{2})$/;

// ---------- dates ----------

function pad(n) {
  return n < 10 ? `0${n}` : `${n}`;
}

/** Today in the viewer's own calendar, as YYYY-MM-DD. */
export function todayIso(now = new Date()) {
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/**
 * "12 Sep", with the year only when it is not the viewer's current one - or always, for the
 * expanded card, which spells its dates out in full.
 */
function formatParts(year, monthIndex, day, currentYear, withYear) {
  const base = `${day} ${MONTHS[monthIndex]}`;
  return withYear || year !== currentYear ? `${base} ${year}` : base;
}

/**
 * A start or due date. These are calendar days, not instants, and arrive as YYYY-MM-DD, so the
 * day is read from the string's own parts. `new Date('2026-09-24')` would parse it as midnight
 * UTC and show 23 Sep to anyone west of Greenwich. Anything that is not a real YYYY-MM-DD day
 * formats as null, and the caller leaves the date out.
 */
export function formatDay(value, now = new Date(), withYear = false) {
  const match = ISO_DAY.exec(value || "");
  if (!match) {
    return null;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const check = new Date(Date.UTC(year, month - 1, day));
  if (check.getUTCMonth() !== month - 1 || check.getUTCDate() !== day) {
    return null;
  }
  return formatParts(year, month - 1, day, now.getFullYear(), withYear);
}

/** When a record was created: a real instant, so it shows as the viewer's own date. */
export function formatInstant(value, now = new Date(), withYear = false) {
  if (!value) {
    return null;
  }
  const when = new Date(value);
  if (Number.isNaN(when.getTime())) {
    return null;
  }
  return formatParts(
    when.getFullYear(),
    when.getMonth(),
    when.getDate(),
    now.getFullYear(),
    withYear
  );
}

/**
 * Past its due date and not finished. The due date is a calendar day, compared with the
 * viewer's today as strings - YYYY-MM-DD sorts as it reads. A card due today is not overdue.
 */
export function isOverdue(card, now = new Date()) {
  if (!card || !ISO_DAY.test(card.dueDate || "") || card.status === DONE) {
    return false;
  }
  return card.dueDate < todayIso(now);
}

/**
 * The date line's parts, in reading order: Created, Start, Due, then Overdue when the board
 * asks for it. Each part after the first carries a separator, which the template hides from
 * screen readers - "Created 12 Sep dot Start..." is noise.
 */
export function dateParts(
  card,
  { showOverdue = false, now = new Date(), withYear = false } = {}
) {
  const parts = [];
  const add = (key, text, cssClass) => {
    if (text) {
      parts.push({
        key,
        text,
        cssClass: cssClass || "date",
        showSep: parts.length > 0
      });
    }
  };
  const created = formatInstant(card.createdAt, now, withYear);
  const start = formatDay(card.startDate, now, withYear);
  const due = formatDay(card.dueDate, now, withYear);
  add("created", created && `Created ${created}`);
  add("start", start && `Start ${start}`);
  add("due", due && `Due ${due}`);
  if (showOverdue && isOverdue(card, now)) {
    add("overdue", "Overdue", "date overdue");
  }
  return parts;
}

// ---------- identity ----------

/**
 * The identifiers a card shows under its heading: the record number, then the source's own key
 * when it has a distinct one. A source whose records have no key of their own shows the number
 * once. Whatever is already standing in as the heading is not repeated here.
 */
export function idParts(recordNumber, externalKey, heading) {
  const ids = [];
  [recordNumber, externalKey].forEach((value) => {
    if (value && value !== heading && !ids.some((id) => id.text === value)) {
      ids.push({
        key: `id-${ids.length}`,
        text: value,
        showSep: ids.length > 0
      });
    }
  });
  return ids;
}

// ---------- cards ----------

/** Parts joined for a screen reader: commas are pauses, where the eye gets a gap or a dot. */
function spoken(parts) {
  return parts.filter((part) => !!part).join(", ");
}

/** The chip for a sync state worth a second look. Synced, and no sync state at all, show none. */
function syncChip(syncStatus) {
  if (syncStatus === PENDING) {
    return { show: true, cssClass: "chip sync sync-pending" };
  }
  if (syncStatus === FAILED) {
    return { show: true, cssClass: "chip sync sync-failed" };
  }
  return { show: false, cssClass: "" };
}

/**
 * A collapsed card's view model, from either board's card payload.
 *
 * @param item a card from getBoardData or getPublicBoardData
 * @param options.key what the board keys this card on - the internal board has ids, the public
 *                    board only auto numbers
 * @param options.showOverdue the internal board only; the public board shows dates, not verdicts
 */
export function cardModel(
  item,
  { key, showOverdue = false, now = new Date() } = {}
) {
  const hasTitle = !!item.title;
  // With no title synced, the source's key stands in, then the record number. Marked, so an
  // untitled card does not pose as a titled one.
  const heading = item.title || item.externalKey || item.recordNumber;
  const sync = syncChip(item.syncStatus);
  const dates = dateParts(item, { showOverdue, now });
  const datesLong = dateParts(item, { showOverdue, now, withYear: true });
  const ids = idParts(item.recordNumber, item.externalKey, heading);
  return {
    key: key || item.recordNumber,
    recordNumber: item.recordNumber,
    externalKey: item.externalKey || null,
    heading,
    hasTitle,
    headingClass: hasTitle ? "heading" : "heading is-fallback",
    ids,
    status: item.status,
    type: item.type || null,
    hasType: !!item.type,
    sourceLabel: item.sourceLabel || null,
    hasSourceLabel: !!item.sourceLabel,
    // A token the stylesheet maps to a colour. Anything it does not know - including no token
    // at all - renders neutral.
    accent: item.accentToken || "none",
    syncStatus: item.syncStatus || null,
    showSync: sync.show,
    syncClass: sync.cssClass,
    dates,
    hasDates: dates.length > 0,
    // What a screen reader hears for the two meta lines, which are hidden from it and drawn
    // for the eye instead. LWC drops whitespace between tags, so spans read side by side run
    // together - "JiraWI-0003" - and the separator dots would be read aloud.
    metaSpoken: spoken([
      item.sourceLabel,
      ...ids.map((id) => id.text),
      item.type
    ]),
    datesSpoken: spoken(dates.map((part) => part.text)),
    // The expanded card's date line: the same dates, each with its year.
    datesLong,
    datesLongSpoken: spoken(datesLong.map((part) => part.text)),
    isOverdue: showOverdue && isOverdue(item, now),
    // What the expanded card adds. Absent from the public payload, and so absent there.
    title: item.title || "",
    startDate: item.startDate || "",
    dueDate: item.dueDate || "",
    sourceName: sourceName(item.sourceLabel),
    supportsStartDate: !!item.supportsStartDate,
    description: item.description || null,
    hasDescription: !!item.description,
    projectLabel: item.projectLabel || null,
    hasProjectLabel: !!item.projectLabel,
    // Set by the board: the parent it can name, and the sync explanation it can give.
    parentLine: null,
    syncNote: null,
    condensesIntoEpic: !!item.condensesIntoEpic,
    isEpic: false,
    showParentNote: false,
    parentNote: null,
    children: [],
    hasChildren: false
  };
}

/** A source's name for a sentence: its label, or a phrase that names none. */
export function sourceName(label) {
  return label || "the source system";
}

/**
 * The expanded card's account of its sync state, naming the source by its label. Honest in both
 * directions: it never says the source has changed before it has, and a record that can never
 * push does not claim to be waiting.
 */
export function syncNote({ syncStatus, syncError, sourceLabel }) {
  const name = sourceName(sourceLabel);
  if (syncStatus === PENDING) {
    return `Pending: saved in Salesforce, and the ${name} update is running.`;
  }
  if (syncStatus === FAILED) {
    const reason = syncError ? ` ${syncError}` : "";
    // Not "save again": a save with nothing changed saves nothing. The failed fields stay
    // queued on the record and go out with the next change that is saved.
    return `Failed: ${name} did not accept the last change.${reason} It is sent again with the next change you save.`;
  }
  if (syncStatus === "Synced") {
    return `In step with ${name}.`;
  }
  return `Not linked to a ${name} record, so nothing is sent.`;
}

/** The statuses a card can move to: the board's columns, less the one it is in. */
export function moveOptions(columns, status) {
  return (columns || [])
    .filter((column) => column !== status)
    .map((column) => ({ key: column, label: column }));
}

/**
 * The expanded card's checks, run before a save is sent. They mirror
 * WorkItemBoardController.saveDetails, which runs them again and is the one that counts: the
 * messages match so a problem reads the same whichever side caught it. Keyed like the server's
 * fieldErrors - title, startDate, dueDate - so each sits beside its field.
 *
 * Dates are compared as YYYY-MM-DD strings, which sort as they read. No Date is built.
 */
export function detailErrors(
  { title, startDate, dueDate },
  { titleMax, supportsStartDate, sourceLabel }
) {
  const errors = {};
  const clean = (title || "").trim();
  if (!clean) {
    errors.title = "A title is required. Type one before saving.";
  } else if (titleMax && clean.length > titleMax) {
    errors.title =
      `The title is ${clean.length} characters; the limit is ${titleMax}. ` +
      `Shorten it by ${clean.length - titleMax}.`;
  }
  if (startDate && !ISO_DAY.test(startDate)) {
    errors.startDate =
      "The start date is not a date. Pick one from the calendar, or clear it.";
  }
  if (dueDate && !ISO_DAY.test(dueDate)) {
    errors.dueDate =
      "The due date is not a date. Pick one from the calendar, or clear it.";
  }
  if (startDate && !supportsStartDate && !errors.startDate) {
    errors.startDate = `${sourceLabel || "This source"} does not support start dates. Clear the start date to save.`;
  }
  if (
    startDate &&
    dueDate &&
    !errors.startDate &&
    !errors.dueDate &&
    startDate > dueDate
  ) {
    errors.startDate = `The start date (${startDate}) is after the due date (${dueDate}). Move one of them.`;
  }
  return errors;
}

/** An epic card's view model. The public payload carries no identifier; the internal one does. */
export function epicModel(epic, { key } = {}) {
  const total = epic.totalChildren || 0;
  const done = epic.completedChildren || 0;
  const percent = total > 0 ? Math.round((done / total) * 100) : 0;
  return {
    key,
    isEpic: true,
    recordNumber: epic.recordNumber || null,
    hasRecordNumber: !!epic.recordNumber,
    // Labelled here rather than falling back to an identifier: the public payload has none.
    heading: epic.title || "Untitled epic",
    headingClass: epic.title ? "heading" : "heading is-fallback",
    id: epic.id || null,
    status: epic.status,
    sourceLabel: epic.sourceLabel || null,
    hasSourceLabel: !!epic.sourceLabel,
    accent: epic.accentToken || "none",
    metaSpoken: spoken([epic.sourceLabel, epic.recordNumber, epic.status]),
    hasChildren: total > 0,
    // "0 of 0" reads as broken. An epic with nothing under it says so in words.
    progressLabel:
      total > 0 ? `${done} of ${total} done` : "No child items yet",
    barStyle: `width: ${percent}%`
  };
}

// ---------- filters ----------

/**
 * The Source filter's options: every label in the data, alphabetically, after "All sources".
 * Read from the payload rather than configured, so a new source appears here when its first
 * record does, with no component change.
 */
export function sourceOptions(...lists) {
  const labels = new Set();
  lists.forEach((list) =>
    (list || []).forEach((entry) => {
      if (entry && entry.sourceLabel) {
        labels.add(entry.sourceLabel);
      }
    })
  );
  return [
    { value: ALL_SOURCES, label: "All sources" },
    ...Array.from(labels)
      .sort((a, b) => a.localeCompare(b))
      .map((label) => ({ value: label, label }))
  ];
}

/** The entries from one source, or all of them. A label, not a vendor: nothing is special-cased. */
export function bySource(list, source) {
  if (!source) {
    return list || [];
  }
  return (list || []).filter((entry) => entry.sourceLabel === source);
}

/**
 * A selected source that has no records left - after a refresh, say - falls back to all sources,
 * rather than leaving the select showing a value it no longer offers over an empty board.
 */
export function keptSource(source, options) {
  return options.some((option) => option.value === source)
    ? source
    : ALL_SOURCES;
}

/** Options for a select, with the current one marked. */
export function selectOptions(options, current) {
  return options.map((option) => ({
    ...option,
    selected: option.value === current
  }));
}

/** "1 item", "3 epics". */
export function countLabel(n, singular, plural) {
  return `${n} ${n === 1 ? singular : plural}`;
}

/**
 * The Epics view holds two kinds of card, so its count names both: "2 epics, 6 items". Counting
 * the flat cards passing through as epics would put "6 epics" over a view with none in it.
 */
export function epicViewCountLabel(epics, items) {
  const parts = [];
  if (epics > 0 || items === 0) {
    parts.push(countLabel(epics, "epic", "epics"));
  }
  if (items > 0) {
    parts.push(countLabel(items, "item", "items"));
  }
  return parts.join(", ");
}
