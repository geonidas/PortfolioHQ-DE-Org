import {
  ALL_SOURCES,
  detailErrors,
  moveOptions,
  syncNote,
  bySource,
  cardModel,
  dateParts,
  epicModel,
  epicViewCountLabel,
  formatDay,
  formatInstant,
  idParts,
  isOverdue,
  keptSource,
  sourceOptions,
  todayIso
} from "c/boardModel";

// Noon on 24 September 2026, local time.
const NOW = new Date(2026, 8, 24, 12, 0, 0);

function item(overrides) {
  return Object.assign(
    {
      recordNumber: "WI-0003",
      title: "Render work items on the board",
      externalKey: "DOPP-17",
      status: "In Progress",
      type: "Story",
      syncStatus: "Synced",
      condensesIntoEpic: true,
      sourceLabel: "Source A",
      accentToken: "accent-1",
      // Noon UTC: the 12th in every zone from UTC-11 to UTC+11.
      createdAt: "2026-09-12T12:00:00.000Z",
      startDate: null,
      dueDate: null
    },
    overrides
  );
}

describe("boardModel dates", () => {
  // jest.config.js runs the suite in America/Los_Angeles. West of Greenwich is where
  // `new Date('YYYY-MM-DD')` goes wrong: it parses as midnight UTC, the previous evening here.
  it("runs in a zone behind UTC, or the next test proves nothing", () => {
    expect(new Date("2026-09-24").getDate()).toBe(23);
  });

  it("formats a calendar day from its own parts, never shifted by the zone", () => {
    expect(formatDay("2026-09-24", NOW)).toBe("24 Sep");
    expect(formatDay("2026-10-01", NOW)).toBe("1 Oct");
    expect(formatDay("2026-01-01", NOW)).toBe("1 Jan");
  });

  it("adds the year only when it is not the current one", () => {
    expect(formatDay("2027-01-05", NOW)).toBe("5 Jan 2027");
    expect(formatDay("2025-12-31", NOW)).toBe("31 Dec 2025");
  });

  it("leaves out a day that is not a real YYYY-MM-DD", () => {
    [
      "",
      null,
      undefined,
      "2026-02-30",
      "2026-9-4",
      "24/09/2026",
      "soon"
    ].forEach((value) => expect(formatDay(value, NOW)).toBeNull());
  });

  it("shows when a record was created as the viewer's own date", () => {
    // 03:00 UTC on the 13th is still the 12th in Los Angeles.
    expect(formatInstant("2026-09-13T03:00:00.000Z", NOW)).toBe("12 Sep");
    expect(formatInstant("not a time", NOW)).toBeNull();
    expect(formatInstant(null, NOW)).toBeNull();
  });

  it("takes today from the viewer's calendar", () => {
    expect(todayIso(NOW)).toBe("2026-09-24");
  });

  it("calls a card overdue only after its due day, and never once it is done", () => {
    expect(isOverdue(item({ dueDate: "2026-09-23" }), NOW)).toBe(true);
    expect(isOverdue(item({ dueDate: "2026-09-24" }), NOW)).toBe(false);
    expect(isOverdue(item({ dueDate: "2026-09-25" }), NOW)).toBe(false);
    expect(
      isOverdue(item({ dueDate: "2026-09-01", status: "Done" }), NOW)
    ).toBe(false);
    expect(isOverdue(item({ dueDate: null }), NOW)).toBe(false);
  });

  it("lays the date line out in reading order with a separator after the first", () => {
    const parts = dateParts(
      item({ startDate: "2026-09-24", dueDate: "2026-10-01" }),
      { now: NOW }
    );
    expect(parts.map((p) => p.text)).toEqual([
      "Created 12 Sep",
      "Start 24 Sep",
      "Due 1 Oct"
    ]);
    expect(parts.map((p) => p.showSep)).toEqual([false, true, true]);
  });

  it("adds Overdue only when the board asks for it", () => {
    const late = item({ dueDate: "2026-09-20" });
    expect(dateParts(late, { now: NOW }).map((p) => p.key)).not.toContain(
      "overdue"
    );
    const flagged = dateParts(late, { showOverdue: true, now: NOW });
    expect(flagged[flagged.length - 1]).toMatchObject({
      key: "overdue",
      text: "Overdue",
      cssClass: "date overdue"
    });
  });
});

describe("boardModel identity", () => {
  it("shows the record number and the source's key", () => {
    expect(idParts("WI-0003", "DOPP-17", "A title").map((i) => i.text)).toEqual(
      ["WI-0003", "DOPP-17"]
    );
  });

  it("shows the record number once when the source has no key of its own", () => {
    expect(idParts("WI-0015", null, "A title").map((i) => i.text)).toEqual([
      "WI-0015"
    ]);
    expect(idParts("WI-0015", "WI-0015", "A title")).toHaveLength(1);
  });

  it("does not repeat what is already standing in as the heading", () => {
    expect(idParts("WI-0003", "DOPP-17", "DOPP-17").map((i) => i.text)).toEqual(
      ["WI-0003"]
    );
    expect(idParts("WI-0015", null, "WI-0015")).toEqual([]);
  });
});

describe("boardModel cards", () => {
  it("heads a card with its title", () => {
    const card = cardModel(item(), { now: NOW });
    expect(card.heading).toBe("Render work items on the board");
    expect(card.headingClass).toBe("heading");
    expect(card.key).toBe("WI-0003");
  });

  it("falls back to the key, then the number, and marks the fallback", () => {
    expect(cardModel(item({ title: null }), { now: NOW })).toMatchObject({
      heading: "DOPP-17",
      headingClass: "heading is-fallback"
    });
    expect(
      cardModel(item({ title: null, externalKey: null }), { now: NOW }).heading
    ).toBe("WI-0003");
  });

  it("shows a sync chip for Pending and Failed only", () => {
    expect(cardModel(item({ syncStatus: "Pending" })).syncClass).toBe(
      "chip sync sync-pending"
    );
    expect(cardModel(item({ syncStatus: "Failed" })).syncClass).toBe(
      "chip sync sync-failed"
    );
    expect(cardModel(item({ syncStatus: "Synced" })).showSync).toBe(false);
    // No remote record: no sync state at all, so nothing to flag.
    expect(cardModel(item({ syncStatus: null })).showSync).toBe(false);
  });

  it("paints a token and falls back to neutral without one", () => {
    expect(cardModel(item()).accent).toBe("accent-1");
    expect(cardModel(item({ accentToken: null })).accent).toBe("none");
  });

  it("spells the meta lines out for a screen reader, without separators", () => {
    const card = cardModel(item({ dueDate: "2026-10-01" }), { now: NOW });
    expect(card.metaSpoken).toBe("Source A, WI-0003, DOPP-17, Story");
    expect(card.datesSpoken).toBe("Created 12 Sep, Due 1 Oct");
    expect(card.metaSpoken).not.toContain("·");
  });

  it("drops what is missing rather than speaking a gap", () => {
    const card = cardModel(
      item({
        sourceLabel: null,
        externalKey: null,
        type: null,
        createdAt: null
      }),
      { now: NOW }
    );
    expect(card.metaSpoken).toBe("WI-0003");
    expect(card.hasDates).toBe(false);
  });

  it("reads an epic with no children as empty, not broken", () => {
    expect(epicModel({ title: "E", status: "To Do" }).progressLabel).toBe(
      "No child items yet"
    );
    const epic = epicModel({
      title: "E",
      status: "In Progress",
      totalChildren: 4,
      completedChildren: 3
    });
    expect(epic.progressLabel).toBe("3 of 4 done");
    expect(epic.barStyle).toBe("width: 75%");
  });

  it("labels an untitled epic instead of inventing an identifier", () => {
    expect(epicModel({ title: null, status: "To Do" })).toMatchObject({
      heading: "Untitled epic",
      headingClass: "heading is-fallback",
      hasRecordNumber: false
    });
  });
});

describe("boardModel open card", () => {
  it("spells dates out with their year when asked", () => {
    expect(formatDay("2026-09-24", NOW, true)).toBe("24 Sep 2026");
    expect(
      cardModel(item({ dueDate: "2026-10-01" }), { now: NOW }).datesLongSpoken
    ).toBe("Created 12 Sep 2026, Due 1 Oct 2026");
  });

  it("explains each sync state by the source's label, and never overclaims", () => {
    const at = (syncStatus, syncError) =>
      syncNote({ syncStatus, syncError, sourceLabel: "Source A" });
    expect(at("Pending")).toBe(
      "Pending: saved in Salesforce, and the Source A update is running."
    );
    expect(at("Synced")).toBe("In step with Source A.");
    expect(at("Failed", "Refused: no such transition.")).toBe(
      "Failed: Source A did not accept the last change. Refused: no such transition. " +
        "Retry sends it again, and so does the next change you save."
    );
    // No sync state: the record has no remote record, and says so rather than "Pending".
    expect(at(null)).toBe(
      "Not linked to a Source A record, so nothing is sent."
    );
    expect(syncNote({ syncStatus: "Synced" })).toBe(
      "In step with the source system."
    );
  });

  it("offers every column but the card's own", () => {
    expect(
      moveOptions(["To Do", "In Progress", "Done"], "In Progress").map(
        (o) => o.key
      )
    ).toStrictEqual(["To Do", "Done"]);
    expect(moveOptions(undefined, "To Do")).toStrictEqual([]);
  });

  it("checks a draft the way saveDetails does, in the same words", () => {
    const rules = {
      titleMax: 10,
      supportsStartDate: true,
      sourceLabel: "Source A"
    };
    expect(
      detailErrors({ title: "Fine", startDate: "", dueDate: "" }, rules)
    ).toStrictEqual({});
    expect(detailErrors({ title: "  " }, rules).title).toBe(
      "A title is required. Type one before saving."
    );
    expect(detailErrors({ title: "x".repeat(12) }, rules).title).toBe(
      "The title is 12 characters; the limit is 10. Shorten it by 2."
    );
    expect(
      detailErrors(
        { title: "Fine", startDate: "2026-10-02", dueDate: "2026-10-01" },
        rules
      ).startDate
    ).toBe(
      "The start date (2026-10-02) is after the due date (2026-10-01). Move one of them."
    );
    expect(
      detailErrors(
        { title: "Fine", startDate: "2026-10-02" },
        { ...rules, supportsStartDate: false }
      ).startDate
    ).toBe(
      "Source A does not support start dates. Clear the start date to save."
    );
    expect(
      detailErrors({ title: "Fine", dueDate: "2026-02-30x" }, rules).dueDate
    ).toBe(
      "The due date is not a date. Pick one from the calendar, or clear it."
    );
  });
});

describe("boardModel counts", () => {
  it("counts the Epics view as epics and the items passing through it", () => {
    expect(epicViewCountLabel(2, 6)).toBe("2 epics, 6 items");
    expect(epicViewCountLabel(1, 1)).toBe("1 epic, 1 item");
    expect(epicViewCountLabel(0, 6)).toBe("6 items");
    expect(epicViewCountLabel(3, 0)).toBe("3 epics");
    expect(epicViewCountLabel(0, 0)).toBe("0 epics");
  });
});

describe("boardModel filters", () => {
  const items = [
    item({ recordNumber: "WI-1", sourceLabel: "Source B" }),
    item({ recordNumber: "WI-2", sourceLabel: "Source A" }),
    item({ recordNumber: "WI-3", sourceLabel: null })
  ];
  const epics = [{ title: "E", sourceLabel: "Source C" }];

  it("offers every label in the data, sorted, after All sources", () => {
    expect(sourceOptions(items, epics)).toEqual([
      { value: ALL_SOURCES, label: "All sources" },
      { value: "Source A", label: "Source A" },
      { value: "Source B", label: "Source B" },
      { value: "Source C", label: "Source C" }
    ]);
  });

  it("keeps one source's entries, or all of them", () => {
    expect(bySource(items, "Source B").map((i) => i.recordNumber)).toEqual([
      "WI-1"
    ]);
    expect(bySource(items, ALL_SOURCES)).toHaveLength(3);
  });

  it("falls back to all sources when the chosen one has gone", () => {
    const options = sourceOptions(items, []);
    expect(keptSource("Source B", options)).toBe("Source B");
    expect(keptSource("Source C", options)).toBe(ALL_SOURCES);
  });
});

describe("boardModel priority (build 09)", () => {
  it("carries the label and rank as sent, and says the priority aloud", () => {
    const card = cardModel(
      item({ dueDate: "2026-10-02", priority: "First", priorityRank: 1 }),
      { now: NOW }
    );
    expect(card).toMatchObject({
      priority: "First",
      hasPriority: true,
      priorityRank: 1,
      hasDateRow: true
    });
    expect(card.datesSpoken).toBe("Created 12 Sep, Due 2 Oct, Priority: First");
    expect(card.datesLongSpoken).toBe(
      "Created 12 Sep 2026, Due 2 Oct 2026, Priority: First"
    );
  });

  it("says nothing of a priority there is none of", () => {
    const card = cardModel(item({ priority: null, priorityRank: null }), {
      now: NOW
    });
    expect(card).toMatchObject({
      priority: null,
      hasPriority: false,
      priorityRank: null
    });
    expect(card.datesSpoken).toBe("Created 12 Sep");
  });

  it("keeps the row for a priority when there are no dates", () => {
    const card = cardModel(
      item({ createdAt: null, priority: "Third", priorityRank: 3 }),
      { now: NOW }
    );
    expect(card.hasDates).toBe(false);
    expect(card.hasDateRow).toBe(true);
    expect(card.datesSpoken).toBe("Priority: Third");
  });

  it("reads whether the source holds a priority from the payload, never from its name", () => {
    expect(cardModel(item({ supportsPriority: true })).supportsPriority).toBe(
      true
    );
    expect(cardModel(item()).supportsPriority).toBe(false);
  });
});
