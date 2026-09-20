import { createElement } from "lwc";
import PublicWorkItemBoard from "c/publicWorkItemBoard";
import getPublicBoardData from "@salesforce/apex/PublicBoardController.getPublicBoardData";

jest.mock(
  "@salesforce/apex/PublicBoardController.getPublicBoardData",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);

const flush = () => Promise.resolve();

/**
 * Deliberately the guest DTO shape, not an SObject. If PublicBoardController's DTO changes, these
 * fixtures stop matching it and the mismatch shows up here rather than on a public page.
 */
function card(overrides) {
  return Object.assign(
    {
      recordNumber: "WI-0000",
      title: "Render work items on the board",
      externalKey: "DOPP-17",
      status: "To Do",
      type: "Story",
      projectLabel: "PHQ",
      parentNumber: null,
      syncStatus: "Synced",
      lastSyncedAt: "2026-09-13T05:20:07.000Z",
      // The server decides this from BoardSourceRules and publishes the answer, not the
      // vendor's name. Jira-sourced work condenses; work from a system with no epics does not.
      condensesIntoEpic: true
    },
    overrides
  );
}

/** A card from a source with no epics: flat, and untouched by the epic toggle. */
function flatCard(overrides) {
  return card(
    Object.assign(
      {
        recordNumber: "WI-9000",
        title: "Superbadge: Apex Specialist",
        externalKey: null,
        type: "Task",
        condensesIntoEpic: false
      },
      overrides
    )
  );
}

function epic(overrides) {
  return Object.assign(
    {
      title: "Guest board",
      status: "In Progress",
      totalChildren: 4,
      completedChildren: 1
    },
    overrides
  );
}

function board(items, epics) {
  return {
    items,
    epics: epics || [],
    itemCount: items.length,
    projectLabel: "PHQ",
    lastSyncedAt: "2026-09-13T05:20:07.000Z"
  };
}

function mount(props) {
  const element = createElement("c-public-work-item-board", {
    is: PublicWorkItemBoard
  });
  Object.assign(element, props || {});
  document.body.appendChild(element);
  return element;
}

const columnNames = (el) =>
  Array.from(el.shadowRoot.querySelectorAll("[data-column]")).map((c) =>
    c.getAttribute("data-column")
  );
const cards = (el) =>
  Array.from(el.shadowRoot.querySelectorAll("c-public-work-item-card"));
const epicCards = (el) =>
  Array.from(el.shadowRoot.querySelectorAll("c-public-epic-card"));
const toggle = (el, view) =>
  el.shadowRoot.querySelector(`button[data-view="${view}"]`);
const epicColumn = (el, status) =>
  el.shadowRoot.querySelector(`[data-epic-column="${status}"]`);
const epicColumnNames = (el) =>
  Array.from(el.shadowRoot.querySelectorAll("[data-epic-column]")).map((c) =>
    c.getAttribute("data-epic-column")
  );

describe("c-public-work-item-board", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("renders cards from the guest DTO shape", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([card({ recordNumber: "WI-0001", status: "To Do" })])
    );
    await flush();

    const rendered = cards(element);
    expect(rendered).toHaveLength(1);
    expect(rendered[0].shadowRoot.querySelector("h3").textContent).toBe(
      "Render work items on the board"
    );
    expect(rendered[0].shadowRoot.querySelector(".num").textContent).toBe(
      "WI-0001 · DOPP-17"
    );
  });

  it("takes its columns from configuration, not from the markup", async () => {
    const element = mount({ columns: "Backlog,Shipping" });
    getPublicBoardData.emit(board([card({ status: "Backlog" })]));
    await flush();

    expect(columnNames(element)).toEqual(["Backlog", "Shipping"]);
    expect(columnNames(element)).not.toContain("To Do");
  });

  it("defaults to the three configured statuses", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()]));
    await flush();

    expect(columnNames(element)).toEqual(["To Do", "In Progress", "Done"]);
  });

  it("falls back to the key when no title has synced, and marks it as a fallback", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card({ title: null })]));
    await flush();

    const heading = cards(element)[0].shadowRoot.querySelector("h3");
    expect(heading.textContent).toBe("DOPP-17");
    // An untitled card should not pose as a titled one.
    expect(heading.className).toContain("is-fallback");
  });

  it("renders no type badge when the DTO sends a null type", async () => {
    const element = mount();
    // The Apex flattens Unspecified to null, so the component never sees the sentinel.
    getPublicBoardData.emit(board([card({ type: null })]));
    await flush();

    expect(cards(element)[0].shadowRoot.querySelector(".badge")).toBeNull();
  });

  it("flags a record that is not reconciled with Jira", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card({ syncStatus: "Pending" })]));
    await flush();

    expect(
      cards(element)[0].shadowRoot.querySelector(".sync-flag").textContent
    ).toBe("Pending");
  });

  it("nests a child under its parent when both sit in one column", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([
        card({
          recordNumber: "WI-0002",
          externalKey: "DOPP-16",
          status: "To Do"
        }),
        card({
          recordNumber: "WI-0003",
          externalKey: "DOPP-17",
          status: "To Do",
          parentNumber: "WI-0002"
        })
      ])
    );
    await flush();

    const nested = element.shadowRoot.querySelector(
      '[data-column="To Do"] .children'
    );
    expect(nested).not.toBeNull();
    expect(nested.querySelectorAll("c-public-work-item-card")).toHaveLength(1);
  });

  it("renders a child whose parent is withheld, with no note about it", async () => {
    const element = mount();
    // parentNumber is null because the Apex only resolves a parent that is itself public.
    getPublicBoardData.emit(
      board([card({ recordNumber: "WI-0003", parentNumber: null })])
    );
    await flush();

    expect(cards(element)).toHaveLength(1);
    // Saying "parent not shown" would reveal that a withheld record exists.
    expect(element.shadowRoot.textContent).not.toMatch(/parent/i);
  });

  it("surfaces a status the columns do not account for instead of dropping it", async () => {
    const element = mount({ columns: "To Do,Done" });
    getPublicBoardData.emit(board([card({ status: "In Progress" })]));
    await flush();

    const other = element.shadowRoot.querySelector('[data-region="other"]');
    expect(other).not.toBeNull();
    expect(other.querySelectorAll("c-public-work-item-card")).toHaveLength(1);
  });

  it("explains an empty board", async () => {
    const element = mount();
    getPublicBoardData.emit(board([]));
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-state="empty"]').textContent
    ).toContain("Nothing to show yet");
  });

  it("shows a fixed message on failure and never the server detail", async () => {
    const element = mount();
    getPublicBoardData.error(
      { message: "SELECT Is_Public__c FROM Work_Item__c failed" },
      400,
      "Bad Request"
    );
    await flush();

    const error = element.shadowRoot.querySelector('[data-state="error"]');
    expect(error.textContent).toContain("unavailable");
    // A server message can carry field and query names to an anonymous visitor.
    expect(error.textContent).not.toContain("Is_Public__c");
    expect(error.textContent).not.toContain("SELECT");
  });

  // ---------- the two views (build 06) ----------

  it("switches views without going back to the server", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic()]));
    await flush();

    // A wire re-invokes only when its config changes, so capturing the config and comparing
    // it after the toggle is what actually proves no refetch happened. A counter on the
    // adapter's emit would have passed whether or not it were true.
    const configOnLoad = getPublicBoardData.getLastConfig();
    // Empty, because the Apex method takes no parameters. Give the wire a reactive config
    // and this fails - which is the point: a config is the only thing that could refetch.
    expect(configOnLoad).toEqual({});
    expect(cards(element)).toHaveLength(1);
    expect(epicCards(element)).toHaveLength(0);

    toggle(element, "epics").click();
    await flush();

    expect(epicCards(element)).toHaveLength(1);
    expect(cards(element)).toHaveLength(0);

    toggle(element, "tasks").click();
    await flush();

    expect(cards(element)).toHaveLength(1);
    // Unchanged across both switches. getPublicBoardData takes no parameters, so the
    // component holds no wire config it could vary even if it wanted to.
    expect(getPublicBoardData.getLastConfig()).toEqual(configOnLoad);
  });

  it("reports which view is on screen", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic()]));
    await flush();

    expect(toggle(element, "tasks").getAttribute("aria-pressed")).toBe("true");
    expect(toggle(element, "epics").getAttribute("aria-pressed")).toBe("false");

    toggle(element, "epics").click();
    await flush();

    expect(toggle(element, "tasks").getAttribute("aria-pressed")).toBe("false");
    expect(toggle(element, "epics").getAttribute("aria-pressed")).toBe("true");
  });

  it("gives each view its own empty state", async () => {
    const element = mount();
    // Epics exist, so the board is not globally empty - but no task is visible.
    getPublicBoardData.emit(board([], [epic({ status: "In Progress" })]));
    await flush();

    const taskEmpty = element.shadowRoot.querySelector('[data-empty="tasks"]');
    expect(taskEmpty).not.toBeNull();
    expect(taskEmpty.textContent).toContain("No open work");
    // The global empty state is the wrong message here and must not appear.
    expect(element.shadowRoot.querySelector('[data-state="empty"]')).toBeNull();

    toggle(element, "epics").click();
    await flush();

    expect(epicCards(element)).toHaveLength(1);
    expect(element.shadowRoot.querySelector('[data-empty="epics"]')).toBeNull();
  });

  it("says a first-run org has completed no epics rather than leaving a gap", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic({ status: "In Progress" })]));
    await flush();

    toggle(element, "epics").click();
    await flush();

    const completed = element.shadowRoot.querySelector(
      '[data-empty="completed"]'
    );
    expect(completed).not.toBeNull();
    expect(completed.textContent).toContain("No completed epics yet");
    // The In Progress column holds the one epic, so only Done is empty.
    expect(
      epicColumn(element, "In Progress").querySelector(".col-empty")
    ).toBeNull();
  });

  it("lays epics into the same columns as the task view", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board(
        [card()],
        [
          epic({ title: "Planned", status: "To Do" }),
          epic({ title: "Underway", status: "In Progress" }),
          epic({ title: "Shipped", status: "Done" })
        ]
      )
    );
    await flush();

    const taskColumns = columnNames(element);
    toggle(element, "epics").click();
    await flush();

    expect(epicColumnNames(element)).toEqual(taskColumns);
    expect(epicColumnNames(element)).toEqual(["To Do", "In Progress", "Done"]);
    ["To Do", "In Progress", "Done"].forEach((status) => {
      const col = epicColumn(element, status);
      expect(col.querySelectorAll("c-public-epic-card")).toHaveLength(1);
      expect(col.querySelector(".col-count").textContent).toBe("1");
    });
  });

  it("takes the epic columns from the same configuration as the tasks", async () => {
    const element = mount({ columns: "Backlog,Shipping" });
    getPublicBoardData.emit(board([card()], [epic({ status: "Backlog" })]));
    await flush();

    toggle(element, "epics").click();
    await flush();

    // One column set for the whole board. When Asana tasks join the epic view they land in
    // these columns too, rather than bringing their own.
    expect(epicColumnNames(element)).toEqual(["Backlog", "Shipping"]);
    expect(
      epicColumn(element, "Backlog").querySelectorAll("c-public-epic-card")
    ).toHaveLength(1);
  });

  it("surfaces an epic whose status no column accounts for", async () => {
    const element = mount({ columns: "To Do,Done" });
    getPublicBoardData.emit(board([card()], [epic({ status: "In Progress" })]));
    await flush();

    toggle(element, "epics").click();
    await flush();

    // Same rule as the task view: silently dropping a record from a public page is worse
    // than showing it somewhere unexpected.
    const other = element.shadowRoot.querySelector(
      '[data-region="other-epics"]'
    );
    expect(other).not.toBeNull();
    expect(other.querySelectorAll("c-public-epic-card")).toHaveLength(1);
  });

  it("explains an epic view with no epics at all", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], []));
    await flush();

    toggle(element, "epics").click();
    await flush();

    expect(
      element.shadowRoot.querySelector('[data-empty="epics"]').textContent
      // Reworded in build 07 step 9: the epic view can hold cards that are not epics, so
      // "no epics yet" stopped being the whole truth about an empty one.
    ).toContain("Nothing to roll up yet");
  });

  it("renders an epic as progress rather than as a status alone", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([card()], [epic({ totalChildren: 4, completedChildren: 3 })])
    );
    await flush();

    toggle(element, "epics").click();
    await flush();

    const rendered = epicCards(element)[0].shadowRoot;
    expect(rendered.querySelector(".count").textContent).toBe("3 of 4 done");
    expect(rendered.querySelector(".bar").style.width).toBe("75%");
    // Decorative: the count beside it carries the same information as text.
    expect(rendered.querySelector(".track").getAttribute("aria-hidden")).toBe(
      "true"
    );
  });

  it("reads an epic with nothing under it as empty, not as broken", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([card()], [epic({ totalChildren: 0, completedChildren: 0 })])
    );
    await flush();

    toggle(element, "epics").click();
    await flush();

    const rendered = epicCards(element)[0].shadowRoot;
    expect(rendered.querySelector(".count").textContent).toBe(
      "No child items yet"
    );
    // "0 of 0 done" reads as a bug, so no bar is drawn at all.
    expect(rendered.querySelector(".track")).toBeNull();
  });

  it("labels an untitled epic instead of publishing an identifier for it", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic({ title: null })]));
    await flush();

    toggle(element, "epics").click();
    await flush();

    const heading = epicCards(element)[0].shadowRoot.querySelector("h3");
    expect(heading.textContent).toBe("Untitled epic");
    expect(heading.className).toContain("is-fallback");
  });

  it("keeps epic cards as inert as work item cards", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic()]));
    await flush();

    toggle(element, "epics").click();
    await flush();

    const article = epicCards(element)[0].shadowRoot.querySelector("article");
    expect(article.getAttribute("role")).toBeNull();
    expect(article.getAttribute("tabindex")).toBeNull();
    expect(epicCards(element)[0].shadowRoot.querySelector("button")).toBeNull();
  });

  it("offers no control that could change anything", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()]));
    await flush();

    // Build 06 added a view toggle, so "no buttons at all" is no longer the right
    // assertion - but the guarantee it protected still holds and still needs stating.
    // Every button on this board must be a view toggle: a control that re-renders data
    // already in memory. Anything else appearing here is a control that could act.
    const buttons = Array.from(element.shadowRoot.querySelectorAll("button"));
    expect(buttons.length).toBeGreaterThan(0);
    buttons.forEach((button) => {
      expect(button.dataset.view).toBeDefined();
      expect(button.type).toBe("button");
    });

    // The cards themselves stay inert, which is the half that never changes.
    const article = cards(element)[0].shadowRoot.querySelector("article");
    expect(article.getAttribute("role")).toBeNull();
    expect(article.getAttribute("tabindex")).toBeNull();
  });
});

describe("c-public-work-item-board card freshness", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("renders when each card last agreed with its source", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([card({ lastSyncedAt: "2026-09-13T05:20:07.000Z" })])
    );
    await flush();

    const stamp = cards(element)[0].shadowRoot.querySelector("[data-synced]");
    expect(stamp).not.toBeNull();
    expect(stamp.textContent).toMatch(/^Updated /);
  });

  it("says nothing on a card that has never synced rather than showing a blank stamp", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card({ lastSyncedAt: null })]));
    await flush();

    expect(
      cards(element)[0].shadowRoot.querySelector("[data-synced]")
    ).toBeNull();
  });

  // ---------- a second source on one board (build 07 step 9) ----------

  it("shows flat cards in the task view alongside the rest", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([
        card({ recordNumber: "WI-0001", status: "In Progress" }),
        flatCard({ status: "In Progress" })
      ])
    );
    await flush();

    const titles = cards(element).map(
      (c) => c.shadowRoot.querySelector("h3").textContent
    );
    expect(titles).toContain("Superbadge: Apex Specialist");
    expect(titles).toHaveLength(2);
  });

  it("shows flat cards in the epic view too, in the same column", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board(
        [
          card({ recordNumber: "WI-0001", status: "In Progress" }),
          flatCard({ status: "In Progress" })
        ],
        [epic({ title: "Guest board", status: "To Do" })]
      )
    );
    await flush();

    toggle(element, "epics").click();
    await flush();

    const inProgress = epicColumn(element, "In Progress");
    const rendered = Array.from(
      inProgress.querySelectorAll("c-public-work-item-card")
    ).map((c) => c.shadowRoot.querySelector("h3").textContent);
    expect(rendered).toEqual(["Superbadge: Apex Specialist"]);
  });

  it("condenses cards that roll up and leaves flat ones alone", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board(
        [
          card({ recordNumber: "WI-0001", title: "A story", status: "To Do" }),
          flatCard({ status: "To Do" })
        ],
        [epic({ title: "Guest board", status: "To Do" })]
      )
    );
    await flush();

    // Task view: both cards, no epic cards.
    expect(cards(element)).toHaveLength(2);
    expect(epicCards(element)).toHaveLength(0);

    toggle(element, "epics").click();
    await flush();

    const titles = cards(element).map(
      (c) => c.shadowRoot.querySelector("h3").textContent
    );
    expect(titles).toEqual(["Superbadge: Apex Specialist"]);
    expect(titles).not.toContain("A story");
    expect(epicCards(element)).toHaveLength(1);
  });

  it("never puts a flat card in an orphan region", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board(
        [flatCard({ status: "In Progress" })],
        [epic({ title: "Guest board", status: "To Do" })]
      )
    );
    await flush();

    toggle(element, "epics").click();
    await flush();

    // A flat card's status is a configured column, so it belongs in that column and nowhere
    // else. The Other region exists for statuses the columns do not account for.
    expect(
      element.shadowRoot.querySelector('[data-region="other-epics"]')
    ).toBeNull();
    expect(
      epicColumn(element, "In Progress").querySelector(
        "c-public-work-item-card"
      )
    ).not.toBeNull();
  });

  it("toggling the view issues no new Apex call", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([flatCard({})], [epic({ title: "Guest board" })])
    );
    await flush();

    // Asserted on the wire configuration rather than a call counter: getPublicBoardData takes
    // no parameters, so there is nothing the client could send that would change what comes
    // back, and a config that stays {} is what proves no narrower request was made.
    const before = getPublicBoardData.getLastConfig();
    expect(before).toEqual({});

    toggle(element, "epics").click();
    await flush();
    toggle(element, "tasks").click();
    await flush();

    expect(getPublicBoardData.getLastConfig()).toEqual({});
  });

  it("carries data-view on every button on the board", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([flatCard({})], [epic({ title: "Guest board" })])
    );
    await flush();

    const buttons = Array.from(element.shadowRoot.querySelectorAll("button"));
    expect(buttons.length).toBeGreaterThan(0);
    buttons.forEach((button) => {
      // Cards are inert. The view toggle is the only control on this page, and anything else
      // that gained a button would be a write path on a read-only board.
      expect(button.dataset.view).toBeTruthy();
    });

    toggle(element, "epics").click();
    await flush();

    Array.from(element.shadowRoot.querySelectorAll("button")).forEach(
      (button) => {
        expect(button.dataset.view).toBeTruthy();
      }
    );
  });
});
