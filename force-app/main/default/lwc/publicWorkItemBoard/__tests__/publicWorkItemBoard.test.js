import { createElement } from "lwc";
import PublicWorkItemBoard from "c/publicWorkItemBoard";
import getPublicBoardData from "@salesforce/apex/PublicBoardController.getPublicBoardData";
import { refreshApex } from "@salesforce/apex";

jest.mock(
  "@salesforce/apex",
  () => ({ refreshApex: jest.fn(() => Promise.resolve()) }),
  { virtual: true }
);
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
      // The server decides this from BoardSourceRules and publishes the answer. Work from a
      // source with epics condenses; work from a flat source does not.
      condensesIntoEpic: true,
      // Build 08 step 5. A label to render and a token to paint, never a vendor to branch on.
      sourceLabel: "Jira",
      accentToken: "accent-1",
      createdAt: "2026-09-08T21:59:09.000Z",
      startDate: null,
      dueDate: null,
      // Build 09 step 5: the label to show and the number to sort on.
      priority: null,
      priorityRank: null
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
        condensesIntoEpic: false,
        sourceLabel: "Asana",
        accentToken: "accent-2"
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
      completedChildren: 1,
      sourceLabel: "Jira",
      accentToken: "accent-1"
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
  Array.from(el.shadowRoot.querySelectorAll("c-board-card"));
const epicCards = (el) =>
  Array.from(el.shadowRoot.querySelectorAll("c-board-epic-card"));
const heading = (cardEl) => cardEl.shadowRoot.querySelector(".heading");
const toolbar = (el) => el.shadowRoot.querySelector("c-board-toolbar");
const filter = (el, name) =>
  toolbar(el).shadowRoot.querySelector(`select[data-filter="${name}"]`);
/** Chooses a value in one of the toolbar's selects, as a visitor would. */
async function choose(el, name, value) {
  const control = filter(el, name);
  control.value = value;
  control.dispatchEvent(new CustomEvent("change"));
  await flush();
}
const setView = (el, view) => choose(el, "view", view);
const setSource = (el, source) => choose(el, "source", source);

/**
 * Names every control among the nodes: a filter by its name, Refresh by its action, a card's
 * disclosure as "disclosure", and anything else by its tag - so an unexpected control shows up
 * in the list by what it is.
 *
 * Compared with toStrictEqual. toEqual skips undefined entries in an array, and in step 6 that
 * let a control with no data attribute map to undefined and vanish from the comparison: the
 * guard below passed with a button in every card.
 */
function describeControls(nodes) {
  return Array.from(nodes)
    .filter((node) =>
      node.matches(
        "button, input, select, textarea, a[href], [tabindex], [contenteditable], [role='button'], [draggable='true']"
      )
    )
    .map((node) => {
      if (node.dataset.filter) {
        return node.dataset.filter;
      }
      if (node.dataset.action) {
        return node.dataset.action;
      }
      if (
        node.hasAttribute("data-disclosure") &&
        node.tagName === "BUTTON" &&
        node.hasAttribute("aria-expanded")
      ) {
        return "disclosure";
      }
      if (node.getAttribute("draggable") === "true") {
        return "draggable";
      }
      if (node.dataset.arrow) {
        return `arrow-${node.dataset.arrow}`;
      }
      return node.tagName.toLowerCase();
    });
}

/**
 * Every element in the board, through every shadow root. The cards and the toolbar render in
 * their own shadow trees, so a query on the board's alone would miss a control inside them -
 * which is exactly where one would be added.
 */
function everything(root) {
  const found = [];
  const walk = (node) => {
    node.querySelectorAll("*").forEach((child) => {
      found.push(child);
      if (child.shadowRoot) {
        walk(child.shadowRoot);
      }
    });
  };
  walk(root.shadowRoot);
  return found;
}
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
    expect(heading(rendered[0]).textContent).toBe(
      "Render work items on the board"
    );
    expect(
      rendered[0].shadowRoot.querySelector("[data-meta] .assistive").textContent
    ).toBe("Jira, WI-0001, DOPP-17, Story");
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

    const fallback = heading(cards(element)[0]);
    expect(fallback.textContent).toBe("DOPP-17");
    // An untitled card should not pose as a titled one.
    expect(fallback.className).toContain("is-fallback");
  });

  it("renders no type badge when the DTO sends a null type", async () => {
    const element = mount();
    // The Apex flattens Unspecified to null, so the component never sees the sentinel.
    getPublicBoardData.emit(board([card({ type: null })]));
    await flush();

    expect(
      cards(element)[0].shadowRoot.querySelector("[data-type]")
    ).toBeNull();
  });

  it("flags a record that is not reconciled with its source", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card({ syncStatus: "Pending" })]));
    await flush();

    expect(
      cards(element)[0].shadowRoot.querySelector("[data-sync]").textContent
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
    expect(nested.querySelectorAll("c-board-card")).toHaveLength(1);
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
    expect(other.querySelectorAll("c-board-card")).toHaveLength(1);
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

    await setView(element, "epics");

    expect(epicCards(element)).toHaveLength(1);
    expect(cards(element)).toHaveLength(0);

    await setView(element, "tasks");

    expect(cards(element)).toHaveLength(1);
    // Unchanged across both switches. getPublicBoardData takes no parameters, so the
    // component holds no wire config it could vary even if it wanted to.
    expect(getPublicBoardData.getLastConfig()).toEqual(configOnLoad);
  });

  it("reports which view is on screen", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic()]));
    await flush();

    expect(filter(element, "view").value).toBe("tasks");

    await setView(element, "epics");

    expect(filter(element, "view").value).toBe("epics");
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

    await setView(element, "epics");

    expect(epicCards(element)).toHaveLength(1);
    expect(element.shadowRoot.querySelector('[data-empty="epics"]')).toBeNull();
  });

  it("says a first-run org has completed no epics rather than leaving a gap", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic({ status: "In Progress" })]));
    await flush();

    await setView(element, "epics");

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
    await setView(element, "epics");

    expect(epicColumnNames(element)).toEqual(taskColumns);
    expect(epicColumnNames(element)).toEqual(["To Do", "In Progress", "Done"]);
    ["To Do", "In Progress", "Done"].forEach((status) => {
      const col = epicColumn(element, status);
      expect(col.querySelectorAll("c-board-epic-card")).toHaveLength(1);
      expect(col.querySelector(".col-count").textContent).toBe("1");
    });
  });

  it("takes the epic columns from the same configuration as the tasks", async () => {
    const element = mount({ columns: "Backlog,Shipping" });
    getPublicBoardData.emit(board([card()], [epic({ status: "Backlog" })]));
    await flush();

    await setView(element, "epics");

    // One column set for the whole board. When Asana tasks join the epic view they land in
    // these columns too, rather than bringing their own.
    expect(epicColumnNames(element)).toEqual(["Backlog", "Shipping"]);
    expect(
      epicColumn(element, "Backlog").querySelectorAll("c-board-epic-card")
    ).toHaveLength(1);
  });

  it("surfaces an epic whose status no column accounts for", async () => {
    const element = mount({ columns: "To Do,Done" });
    getPublicBoardData.emit(board([card()], [epic({ status: "In Progress" })]));
    await flush();

    await setView(element, "epics");

    // Same rule as the task view: silently dropping a record from a public page is worse
    // than showing it somewhere unexpected.
    const other = element.shadowRoot.querySelector(
      '[data-region="other-epics"]'
    );
    expect(other).not.toBeNull();
    expect(other.querySelectorAll("c-board-epic-card")).toHaveLength(1);
  });

  it("explains an epic view with no epics at all", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], []));
    await flush();

    await setView(element, "epics");

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

    await setView(element, "epics");

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

    await setView(element, "epics");

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

    await setView(element, "epics");

    const untitled = heading(epicCards(element)[0]);
    expect(untitled.textContent).toBe("Untitled epic");
    expect(untitled.className).toContain("is-fallback");
  });

  it("gives epic cards their disclosure and nothing else", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()], [epic()]));
    await flush();

    await setView(element, "epics");

    const article = epicCards(element)[0].shadowRoot.querySelector("article");
    expect(article.getAttribute("role")).toBeNull();
    expect(article.getAttribute("tabindex")).toBeNull();
    expect(
      describeControls(epicCards(element)[0].shadowRoot.querySelectorAll("*"))
    ).toStrictEqual(["disclosure"]);
  });

  it("offers no control that could change anything", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()]));
    await flush();

    // Build 06 added a view toggle, build 08 a Refresh button, two filters and a disclosure on
    // each card, so "no controls at all" is no longer the right assertion - but the guarantee
    // it protected still holds. The filters and the disclosures re-render what is already in
    // memory; Refresh re-reads through the same parameterless method the page loaded with.
    // Searched through every shadow root: a control added inside a card is still a control.
    expect(describeControls(everything(element))).toStrictEqual([
      "refresh",
      "view",
      "source",
      "sort",
      "disclosure"
    ]);
    everything(element)
      .filter((node) => node.tagName === "BUTTON")
      .forEach((button) => expect(button.type).toBe("button"));

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

  it("shows no per-card Updated line", async () => {
    // Build 08 step 5 removed it and its field. The board-level "Last updated" stays.
    const element = mount();
    getPublicBoardData.emit(board([card()]));
    await flush();

    const text = cards(element)[0].shadowRoot.textContent;
    expect(text).not.toContain("Updated");
    // The board-level line: when the data last changed, in the visitor's own date.
    expect(element.shadowRoot.querySelector(".freshness").textContent).toMatch(
      /^Updated \d{1,2} [A-Z][a-z]{2}/
    );
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

    const titles = cards(element).map((c) => heading(c).textContent);
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

    await setView(element, "epics");

    const inProgress = epicColumn(element, "In Progress");
    const rendered = Array.from(
      inProgress.querySelectorAll("c-board-card")
    ).map((c) => heading(c).textContent);
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

    await setView(element, "epics");

    const titles = cards(element).map((c) => heading(c).textContent);
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

    await setView(element, "epics");

    // A flat card's status is a configured column, so it belongs in that column and nowhere
    // else. The Other region exists for statuses the columns do not account for.
    expect(
      element.shadowRoot.querySelector('[data-region="other-epics"]')
    ).toBeNull();
    expect(
      epicColumn(element, "In Progress").querySelector("c-board-card")
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

    await setView(element, "epics");
    await setView(element, "tasks");

    expect(getPublicBoardData.getLastConfig()).toEqual({});
  });

  it("has no button but Refresh and the disclosures, open or closed, in either view", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([flatCard({})], [epic({ title: "Guest board" })])
    );
    await flush();

    const buttons = () =>
      describeControls(
        everything(element).filter((node) => node.tagName === "BUTTON")
      );
    // Anything else that gained a button would be a write path on a read-only board.
    expect(buttons()).toStrictEqual(["refresh", "disclosure"]);

    // Open, a card shows more and offers nothing more.
    cards(element)[0].shadowRoot.querySelector("[data-disclosure]").click();
    await flush();
    expect(describeControls(everything(element))).toStrictEqual([
      "refresh",
      "view",
      "source",
      "sort",
      "disclosure"
    ]);

    await setView(element, "epics");

    expect(buttons()).toStrictEqual(["refresh", "disclosure", "disclosure"]);
    epicCards(element)[0].shadowRoot.querySelector("[data-disclosure]").click();
    await flush();
    expect(buttons()).toStrictEqual(["refresh", "disclosure", "disclosure"]);
  });

  it("never passes its cards an ability", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board(
        [card({ recordNumber: "WI-0001" }), flatCard({})],
        [epic({ title: "Guest board" })]
      )
    );
    await flush();
    cards(element)[0].shadowRoot.querySelector("[data-disclosure]").click();
    await flush();

    const check = () =>
      [...cards(element), ...epicCards(element)].forEach((cardEl) => {
        expect(cardEl.abilities).toBeUndefined();
        expect(cardEl.recordLink).toBeUndefined();
        expect(cardEl.feedback).toBeUndefined();
      });
    check();
    await setView(element, "epics");
    check();
  });
});

// Build 08 step 7. Cards open in place, one at a time, and show only what the payload carries.
describe("c-public-work-item-board open cards", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  const header = (cardEl) =>
    cardEl.shadowRoot.querySelector("[data-disclosure]");
  const expanded = (el) =>
    cards(el).map((c) => header(c).getAttribute("aria-expanded"));

  it("opens one card at a time", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([
        card({ recordNumber: "WI-0001", status: "To Do" }),
        card({ recordNumber: "WI-0002", status: "In Progress" })
      ])
    );
    await flush();
    expect(expanded(element)).toStrictEqual(["false", "false"]);

    header(cards(element)[0]).click();
    await flush();
    expect(expanded(element)).toStrictEqual(["true", "false"]);

    header(cards(element)[1]).click();
    await flush();
    expect(expanded(element)).toStrictEqual(["false", "true"]);

    header(cards(element)[1]).click();
    await flush();
    expect(expanded(element)).toStrictEqual(["false", "false"]);
  });

  it("shows the public parent and the project, and no description", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([
        card({ recordNumber: "WI-0002", status: "In Progress" }),
        card({
          recordNumber: "WI-0003",
          status: "To Do",
          parentNumber: "WI-0002",
          projectLabel: "PHQ"
        })
      ])
    );
    await flush();
    const child = cards(element).find(
      (c) => c.shadowRoot.querySelector("article").dataset.key === "WI-0003"
    );

    header(child).click();
    await flush();

    expect(child.shadowRoot.querySelector("[data-parent]").textContent).toBe(
      "WI-0002"
    );
    expect(child.shadowRoot.querySelector("[data-project]").textContent).toBe(
      "PHQ"
    );
    // Not in the public payload, so not on the public card - and no sync explanation either.
    expect(child.shadowRoot.querySelector("[data-description]")).toBeNull();
    expect(child.shadowRoot.querySelector("[data-sync-note]")).toBeNull();
  });

  it("says nothing about a parent the visitor cannot see", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card({ parentNumber: null })]));
    await flush();

    header(cards(element)[0]).click();
    await flush();

    expect(
      cards(element)[0].shadowRoot.querySelector("[data-parent]")
    ).toBeNull();
  });

  it("is accessible with a card open, in both views", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([card({ recordNumber: "WI-0001", projectLabel: "PHQ" })], [epic()])
    );
    await flush();
    header(cards(element)[0]).click();
    await flush();
    await expect(element).toBeAccessible();

    await setView(element, "epics");
    header(epicCards(element)[0]).click();
    await flush();
    await expect(element).toBeAccessible();
  });
});

// Build 08 step 9. One column at a time in a portrait window, side by side otherwise.
describe("c-public-work-item-board portrait", () => {
  const PORTRAIT = "(orientation: portrait) and (max-width: 700px)";
  const REDUCED = "(prefers-reduced-motion: reduce)";
  let media;
  let scrolls;

  function mockMedia(values) {
    media = { ...values, listeners: [] };
    window.matchMedia = jest.fn((query) => ({
      get matches() {
        return !!media[query];
      },
      addEventListener: (type, listener) => media.listeners.push(listener),
      removeEventListener: (type, listener) => {
        media.listeners = media.listeners.filter((l) => l !== listener);
      }
    }));
  }

  beforeEach(() => {
    scrolls = [];
    // jsdom lays nothing out and cannot scroll; this records what the track was asked to do.
    Element.prototype.scrollBy = function scrollBy(options) {
      scrolls.push(options);
    };
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    delete window.matchMedia;
    delete Element.prototype.scrollBy;
    jest.useRealTimers();
  });

  const columnsEl = (el) => el.shadowRoot.querySelector("c-board-columns");
  const inColumns = (el, selector) =>
    columnsEl(el).shadowRoot.querySelector(selector);
  const position = (el) => {
    const line = inColumns(el, "[data-position]");
    return line ? line.querySelector(".assistive").textContent : null;
  };
  const arrow = (el, which) => inColumns(el, `[data-arrow="${which}"]`);
  async function loaded(props) {
    const element = mount(props);
    getPublicBoardData.emit(
      board([
        card({ recordNumber: "WI-0001", status: "To Do" }),
        card({ recordNumber: "WI-0002", status: "In Progress" }),
        card({ recordNumber: "WI-0003", status: "Done" })
      ])
    );
    await flush();
    await flush();
    return element;
  }

  it("shows every column side by side in landscape, with no arrows", async () => {
    mockMedia({ [PORTRAIT]: false });
    const element = await loaded();

    expect(arrow(element, "previous")).toBeNull();
    expect(arrow(element, "next")).toBeNull();
    expect(position(element)).toBeNull();
    expect(scrolls).toHaveLength(0);
  });

  it("opens on In Progress in portrait, and says where it is", async () => {
    mockMedia({ [PORTRAIT]: true });
    const element = await loaded();

    expect(position(element)).toBe("In Progress, 2 of 3");
    expect(
      inColumns(element, "[data-position]").getAttribute("aria-live")
    ).toBe("polite");
    // Straight there on opening - no animation to watch.
    expect(scrolls[0].behavior).toBe("auto");
  });

  it("names each arrow for the column it shows", async () => {
    mockMedia({ [PORTRAIT]: true });
    const element = await loaded();

    expect(arrow(element, "previous").getAttribute("aria-label")).toBe(
      "Show To Do column"
    );
    expect(arrow(element, "next").getAttribute("aria-label")).toBe(
      "Show Done column"
    );
  });

  it("hides an arrow at its end, and keeps focus on the one that is left", async () => {
    mockMedia({ [PORTRAIT]: true });
    const element = await loaded();

    arrow(element, "next").click();
    await flush();

    expect(position(element)).toBe("Done, 3 of 3");
    expect(arrow(element, "next")).toBeNull();
    expect(arrow(element, "previous").getAttribute("aria-label")).toBe(
      "Show In Progress column"
    );
    expect(columnsEl(element).shadowRoot.activeElement).toBe(
      arrow(element, "previous")
    );
    expect(scrolls[scrolls.length - 1].behavior).toBe("smooth");

    arrow(element, "previous").click();
    await flush();
    arrow(element, "previous").click();
    await flush();

    expect(position(element)).toBe("To Do, 1 of 3");
    expect(arrow(element, "previous")).toBeNull();
    expect(columnsEl(element).shadowRoot.activeElement).toBe(
      arrow(element, "next")
    );
  });

  it("jumps instead of gliding when less motion is asked for", async () => {
    mockMedia({ [PORTRAIT]: true, [REDUCED]: true });
    const element = await loaded();

    arrow(element, "next").click();
    await flush();

    expect(scrolls[scrolls.length - 1].behavior).toBe("auto");
  });

  it("follows a swipe once the track has settled", async () => {
    mockMedia({ [PORTRAIT]: true });
    const element = await loaded();
    jest.useFakeTimers();
    // Lay the three columns out 300px apart, with the track's centre over the first.
    const columns = element.shadowRoot.querySelectorAll("[data-board-column]");
    columns.forEach((column, index) => {
      column.getBoundingClientRect = () => ({ left: index * 300, width: 280 });
    });
    const track = inColumns(element, "[data-track]");
    track.getBoundingClientRect = () => ({ left: 0, width: 280 });

    track.dispatchEvent(new CustomEvent("scroll"));
    await flush();
    // Still moving: the position line has not changed, so it has announced nothing.
    expect(position(element)).toBe("In Progress, 2 of 3");

    jest.advanceTimersByTime(150);
    await flush();

    expect(position(element)).toBe("To Do, 1 of 3");
  });

  it("opens on the first column when the board has no In Progress", async () => {
    mockMedia({ [PORTRAIT]: true });
    const element = mount({ columns: "Backlog,Doing" });
    getPublicBoardData.emit(board([card({ status: "Backlog" })]));
    await flush();
    await flush();

    expect(position(element)).toBe("Backlog, 1 of 2");
    expect(arrow(element, "previous")).toBeNull();
  });

  it("takes up the portrait layout when the window turns", async () => {
    mockMedia({ [PORTRAIT]: false });
    const element = await loaded();
    expect(arrow(element, "next")).toBeNull();

    media[PORTRAIT] = true;
    media.listeners.forEach((listener) => listener());
    await flush();
    await flush();

    expect(position(element)).toBe("In Progress, 2 of 3");
    expect(arrow(element, "next")).not.toBeNull();
  });

  it("adds no control but the two arrows", async () => {
    mockMedia({ [PORTRAIT]: true });
    const element = await loaded();

    expect(describeControls(everything(element))).toStrictEqual([
      "refresh",
      "view",
      "source",
      "sort",
      "arrow-previous",
      "arrow-next",
      "disclosure",
      "disclosure",
      "disclosure"
    ]);
  });

  it("is accessible in portrait, at an end and in the middle", async () => {
    mockMedia({ [PORTRAIT]: true });
    const element = await loaded();
    await expect(element).toBeAccessible();
    arrow(element, "next").click();
    await flush();
    await expect(element).toBeAccessible();
  });
});

// Build 08 step 6. The toolbar's Source filter and the page's subtitle.
describe("c-public-work-item-board filters and header", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  const mixed = () =>
    board(
      [
        card({ recordNumber: "WI-0001", status: "To Do" }),
        card({ recordNumber: "WI-0002", status: "In Progress" }),
        flatCard({ recordNumber: "WI-0015", status: "To Do" })
      ],
      [epic({ title: "Guest board", status: "In Progress" })]
    );
  const total = (el) => el.shadowRoot.querySelector(".total").textContent;

  it("offers the sources the data names, after All sources", async () => {
    const element = mount();
    getPublicBoardData.emit(mixed());
    await flush();

    expect(
      Array.from(filter(element, "source").options).map((o) =>
        o.textContent.trim()
      )
    ).toEqual(["All sources", "Asana", "Jira"]);
  });

  it("filters the task view by source, and counts what is left", async () => {
    const element = mount();
    getPublicBoardData.emit(mixed());
    await flush();
    expect(total(element)).toBe("3 items");

    await setSource(element, "Asana");

    expect(cards(element).map((c) => heading(c).textContent)).toEqual([
      "Superbadge: Apex Specialist"
    ]);
    expect(total(element)).toBe("1 item");
    expect(
      element.shadowRoot.querySelector('[data-column="To Do"] .col-count')
        .textContent
    ).toBe("1");
  });

  it("filters the epic view too: the epic goes with its source", async () => {
    const element = mount();
    getPublicBoardData.emit(mixed());
    await flush();
    await setView(element, "epics");
    expect(epicCards(element)).toHaveLength(1);
    // Found on the live page: this read "2 epics" - the flat card counted as an epic - and,
    // filtered to the flat source, "1 epic" over a view with no epic in it.
    expect(total(element)).toBe("1 epic, 1 item");

    await setSource(element, "Asana");

    expect(epicCards(element)).toHaveLength(0);
    expect(cards(element)).toHaveLength(1);
    expect(total(element)).toBe("1 item");

    await setSource(element, "Jira");

    expect(epicCards(element)).toHaveLength(1);
    expect(cards(element)).toHaveLength(0);
    expect(total(element)).toBe("1 epic");
  });

  it("filters without going back to the server", async () => {
    const element = mount();
    getPublicBoardData.emit(mixed());
    await flush();

    await setSource(element, "Asana");
    await setView(element, "epics");
    await setSource(element, "");

    // No parameters to send, and none sent: the wire config is what would carry them.
    expect(getPublicBoardData.getLastConfig()).toEqual({});
    expect(refreshApex).not.toHaveBeenCalled();
  });

  it("says when a filter leaves a view empty, and keeps the toolbar to undo it", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board(
        [flatCard({ status: "To Do" })],
        [epic({ title: "Guest board", status: "Done" })]
      )
    );
    await flush();

    // Jira has an epic but no open task on this board.
    await setSource(element, "Jira");

    const empty = element.shadowRoot.querySelector('[data-empty="tasks"]');
    expect(empty.textContent).toContain("Nothing from Jira here.");
    expect(toolbar(element)).not.toBeNull();
    expect(element.shadowRoot.querySelector('[data-state="empty"]')).toBeNull();
  });

  it("falls back to all sources when the chosen one leaves the data", async () => {
    const element = mount();
    getPublicBoardData.emit(mixed());
    await flush();
    await setSource(element, "Asana");

    getPublicBoardData.emit(
      board([card({ recordNumber: "WI-0001", status: "To Do" })])
    );
    await flush();

    expect(filter(element, "source").value).toBe("");
    expect(cards(element)).toHaveLength(1);
  });

  it("shows the subtitle set on the page, and nothing when it is blank", async () => {
    const element = mount({ subtitle: "Work in progress, in public." });
    getPublicBoardData.emit(mixed());
    await flush();
    expect(
      element.shadowRoot.querySelector("[data-subtitle]").textContent
    ).toBe("Work in progress, in public.");

    const blank = mount({ subtitle: "   " });
    getPublicBoardData.emit(mixed());
    await flush();
    expect(blank.shadowRoot.querySelector("[data-subtitle]")).toBeNull();
  });
});

// Build 08 gate. Both views and every state are held to sa11y's rule set separately: the epic
// view renders different cards from the task view, and a violation in one would pass a check
// of the other.
describe("c-public-work-item-board accessibility", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  const busyBoard = () =>
    board(
      [
        card({ recordNumber: "WI-0001", status: "To Do" }),
        card({
          recordNumber: "WI-0002",
          title: "A child",
          status: "To Do",
          parentNumber: "WI-0001"
        }),
        card({
          recordNumber: "WI-0003",
          title: null,
          status: "In Progress",
          syncStatus: "Pending",
          lastSyncedAt: null
        }),
        card({ recordNumber: "WI-0004", status: "Blocked" }),
        flatCard({ status: "Done", type: null })
      ],
      [
        epic({ title: "Guest board", status: "In Progress" }),
        epic({ title: null, status: "To Do", totalChildren: 0 }),
        epic({ title: "Unmapped", status: "Blocked" })
      ]
    );

  it("is accessible while loading", async () => {
    await expect(mount()).toBeAccessible();
  });

  it("is accessible in the task view", async () => {
    const element = mount();
    getPublicBoardData.emit(busyBoard());
    await flush();
    await expect(element).toBeAccessible();
  });

  it("is accessible in the epic view", async () => {
    const element = mount();
    getPublicBoardData.emit(busyBoard());
    await flush();
    await setView(element, "epics");
    await expect(element).toBeAccessible();
  });

  it("is accessible when each view is empty on its own", async () => {
    const element = mount();
    getPublicBoardData.emit(board([], [epic({ status: "Done" })]));
    await flush();
    await expect(element).toBeAccessible();
    await setView(element, "epics");
    await expect(element).toBeAccessible();
  });

  it("is accessible when the whole board is empty", async () => {
    const element = mount();
    getPublicBoardData.emit(board([], []));
    await flush();
    await expect(element).toBeAccessible();
  });

  it("is accessible when the board fails to load", async () => {
    const element = mount();
    getPublicBoardData.error({ message: "Nope" }, 500, "Server Error");
    await flush();
    await expect(element).toBeAccessible();
  });
  it("is accessible with a subtitle and a filter that empties a view", async () => {
    const element = mount({ subtitle: "Work in progress, in public." });
    getPublicBoardData.emit(busyBoard());
    await flush();
    await setSource(element, "Asana");
    await setView(element, "epics");
    await expect(element).toBeAccessible();
  });
});

// Build 08 step 5. LWR sites do not support lightning/empApi, so the public board re-reads: every
// 30 seconds while the page is visible and the visitor is active, and not otherwise.
describe("c-public-work-item-board staying current", () => {
  const setVisibility = (state) => {
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      get: () => state
    });
    document.dispatchEvent(new CustomEvent("visibilitychange"));
  };

  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    setVisibility("visible");
    jest.useRealTimers();
    jest.clearAllMocks();
  });

  async function loaded() {
    const element = mount();
    getPublicBoardData.emit(board([card()]));
    await flush();
    return element;
  }

  it("re-reads every 30 seconds while the page is visible", async () => {
    await loaded();

    jest.advanceTimersByTime(30000);
    expect(refreshApex).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(30000);
    expect(refreshApex).toHaveBeenCalledTimes(2);
  });

  it("re-reads through the same parameterless call, never a narrower one", async () => {
    await loaded();

    jest.advanceTimersByTime(30000);

    expect(getPublicBoardData.getLastConfig()).toEqual({});
  });

  it("stops while the page is hidden and catches up when it returns", async () => {
    await loaded();

    setVisibility("hidden");
    jest.advanceTimersByTime(120000);
    expect(refreshApex).not.toHaveBeenCalled();

    setVisibility("visible");
    expect(refreshApex).toHaveBeenCalledTimes(1);
  });

  it("pauses after five idle minutes, says so, and resumes on activity", async () => {
    const element = await loaded();

    jest.advanceTimersByTime(330000);
    const callsWhileActive = refreshApex.mock.calls.length;
    jest.advanceTimersByTime(120000);
    await flush();

    expect(refreshApex.mock.calls.length).toBe(callsWhileActive);
    expect(element.shadowRoot.querySelector("[data-checked]").textContent).toBe(
      "Paused"
    );

    window.dispatchEvent(new CustomEvent("pointerdown"));
    await flush();

    expect(refreshApex.mock.calls.length).toBe(callsWhileActive + 1);
    expect(
      element.shadowRoot.querySelector("[data-checked]").textContent
    ).not.toBe("Paused");
  });

  it("refreshes on demand, paused or not", async () => {
    const element = await loaded();

    element.shadowRoot.querySelector('[data-action="refresh"]').click();

    expect(refreshApex).toHaveBeenCalledTimes(1);
  });

  it("stops polling and listening when it disconnects", async () => {
    const element = await loaded();

    document.body.removeChild(element);
    jest.advanceTimersByTime(120000);
    window.dispatchEvent(new CustomEvent("pointerdown"));
    setVisibility("visible");

    expect(refreshApex).not.toHaveBeenCalled();
  });
});

describe("c-public-work-item-board priority (build 09)", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  const header = (cardEl) =>
    cardEl.shadowRoot.querySelector("[data-disclosure]");

  it("shows a card's priority read-only, closed and open, and none when it has none", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([
        card({ recordNumber: "WI-0001", priority: "First", priorityRank: 1 }),
        card({ recordNumber: "WI-0002", title: "Another" })
      ])
    );
    await flush();
    const [withOne, without] = cards(element);
    expect(
      withOne.shadowRoot.querySelector("[data-priority]").textContent
    ).toBe("First");
    expect(without.shadowRoot.querySelector("[data-priority]")).toBeNull();

    header(withOne).click();
    await flush();
    expect(
      withOne.shadowRoot.querySelector("[data-priority]").textContent
    ).toBe("First");
    expect(withOne.shadowRoot.querySelector("select, [data-field]")).toBeNull();
    await expect(element).toBeAccessible();
  });
});

describe("c-public-work-item-board sorting (build 09)", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  // One column, varied dates and priorities. Two sources: A condenses into epics, B is flat.
  const mixed = () => [
    card({
      recordNumber: "WI-0001",
      title: "Undated low",
      priority: "Third",
      priorityRank: 3
    }),
    card({
      recordNumber: "WI-0002",
      title: "Late none",
      dueDate: "2026-12-01"
    }),
    card({
      recordNumber: "WI-0003",
      title: "Soon high",
      dueDate: "2026-10-01",
      priority: "First",
      priorityRank: 1
    }),
    flatCard({
      recordNumber: "WI-0004",
      title: "Flat middle",
      dueDate: "2026-11-01",
      priority: "Second",
      priorityRank: 2
    }),
    flatCard({
      recordNumber: "WI-0005",
      title: "Flat undated high",
      priority: "First",
      priorityRank: 1
    })
  ];
  const order = (el) =>
    Array.from(
      el.shadowRoot.querySelectorAll('[data-column="To Do"] c-board-card')
    ).map((node) => node.shadowRoot.querySelector("article").dataset.key);
  const sortBy = async (el, value) => {
    const control = el.shadowRoot
      .querySelector("c-board-toolbar")
      .shadowRoot.querySelector('select[data-filter="sort"]');
    control.value = value;
    control.dispatchEvent(new CustomEvent("change"));
    await flush();
  };

  it("opens sorted by due date, and sorts by priority when asked", async () => {
    const element = mount();
    getPublicBoardData.emit(board(mixed()));
    await flush();
    expect(order(element)).toStrictEqual([
      "WI-0003",
      "WI-0004",
      "WI-0002",
      "WI-0005",
      "WI-0001"
    ]);

    await sortBy(element, "priority");
    expect(order(element)).toStrictEqual([
      "WI-0003",
      "WI-0005",
      "WI-0004",
      "WI-0001",
      "WI-0002"
    ]);
  });

  it("keeps the sort across a poll and a filter change, and sorts within one source", async () => {
    const element = mount();
    getPublicBoardData.emit(board(mixed()));
    await flush();
    await sortBy(element, "priority");

    getPublicBoardData.emit(board(mixed()));
    await flush();
    expect(order(element)[0]).toBe("WI-0003");

    await setSource(element, "Asana");
    expect(order(element)).toStrictEqual(["WI-0005", "WI-0004"]);
    await setSource(element, "");
    expect(order(element)).toStrictEqual([
      "WI-0003",
      "WI-0005",
      "WI-0004",
      "WI-0001",
      "WI-0002"
    ]);
  });

  it("sorts children within their parent in the task view", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board([
        card({ recordNumber: "WI-0010", title: "Parent" }),
        card({
          recordNumber: "WI-0011",
          parentNumber: "WI-0010",
          dueDate: "2026-10-01",
          priority: "Third",
          priorityRank: 3
        }),
        card({
          recordNumber: "WI-0012",
          parentNumber: "WI-0010",
          dueDate: "2026-11-01",
          priority: "First",
          priorityRank: 1
        })
      ])
    );
    await flush();
    const nested = () =>
      Array.from(
        element.shadowRoot.querySelectorAll(
          '[data-column="To Do"] ul.children c-board-card'
        )
      ).map((node) => node.shadowRoot.querySelector("article").dataset.key);

    // Nested under the parent, not beside it, and in the chosen order there.
    expect(nested()).toStrictEqual(["WI-0011", "WI-0012"]);
    await sortBy(element, "priority");
    expect(nested()).toStrictEqual(["WI-0012", "WI-0011"]);
  });

  it("keeps the epics' order in the epic view and sorts the cards passing through", async () => {
    const element = mount();
    getPublicBoardData.emit(
      board(mixed(), [
        epic({ title: "Epic Z", status: "To Do" }),
        epic({ title: "Epic A", status: "To Do" })
      ])
    );
    await flush();
    await setView(element, "epics");
    await sortBy(element, "priority");

    const column = epicColumn(element, "To Do");
    const epicsHere = Array.from(
      column.querySelectorAll("c-board-epic-card")
    ).map((node) => node.shadowRoot.querySelector(".heading").textContent);
    expect(epicsHere).toStrictEqual(["Epic Z", "Epic A"]);
    const passing = Array.from(column.querySelectorAll("c-board-card")).map(
      (node) => node.shadowRoot.querySelector("article").dataset.key
    );
    expect(passing).toStrictEqual(["item-WI-0005", "item-WI-0004"]);

    await sortBy(element, "due");
    expect(
      Array.from(column.querySelectorAll("c-board-card")).map(
        (node) => node.shadowRoot.querySelector("article").dataset.key
      )
    ).toStrictEqual(["item-WI-0004", "item-WI-0005"]);
  });

  it("is accessible sorted by priority", async () => {
    const element = mount();
    getPublicBoardData.emit(board(mixed()));
    await flush();
    await sortBy(element, "priority");
    await expect(element).toBeAccessible();
  });
});
