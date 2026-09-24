import { createElement } from "lwc";
import WorkItemBoard from "c/workItemBoard";
import getBoardData from "@salesforce/apex/WorkItemBoardController.getBoardData";
import changeStatus from "@salesforce/apex/WorkItemBoardController.changeStatus";
import { refreshApex } from "@salesforce/apex";

jest.mock(
  "@salesforce/apex/WorkItemBoardController.getBoardData",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/WorkItemBoardController.changeStatus",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex",
  () => ({ refreshApex: jest.fn(() => Promise.resolve()) }),
  {
    virtual: true
  }
);

const flush = () => Promise.resolve();

function item(overrides) {
  return Object.assign(
    {
      Id: "",
      Name: "WI-0000",
      Title__c: "Reconcile the nightly Jira pull",
      External_Key__c: "DOPP-0",
      Status__c: "To Do",
      Type__c: "Story",
      Sync_Status__c: "Synced",
      Story_Points__c: null,
      Description__c: null,
      Parent_Work_Item__c: null,
      Project__r: { Name: "Portfolio HQ", Short_Name__c: null }
    },
    overrides
  );
}

function board(items) {
  return {
    items,
    itemCount: items.length,
    projectId: null,
    projectLabel: null,
    lastSyncedAt: "2026-09-13T05:20:07.000Z"
  };
}

function mount(props) {
  const element = createElement("c-work-item-board", { is: WorkItemBoard });
  Object.assign(element, props || {});
  document.body.appendChild(element);
  return element;
}

function columnNames(element) {
  return Array.from(element.shadowRoot.querySelectorAll("[data-column]")).map(
    (col) => col.getAttribute("data-column")
  );
}

function cards(element) {
  return Array.from(element.shadowRoot.querySelectorAll("c-work-item-card"));
}

describe("c-work-item-board", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  describe("columns come from configuration", () => {
    it("renders exactly the configured columns and nothing else", async () => {
      const element = mount({ columns: "Backlog,Doing" });
      getBoardData.emit(board([item({ Id: "1", Status__c: "Backlog" })]));
      await flush();

      // The point of the configuration: no status string is baked into the markup, so a
      // board can name its columns anything the org uses.
      expect(columnNames(element)).toEqual(["Backlog", "Doing"]);
      expect(columnNames(element)).not.toContain("To Do");
    });

    it("falls back to the default three when nothing is configured", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1" })]));
      await flush();

      expect(columnNames(element)).toEqual(["To Do", "In Progress", "Done"]);
    });

    it("adds a column from configuration alone, with no code change", async () => {
      // In Review is unreachable in the live Jira board, which is exactly why it must be
      // addable later without touching this component.
      const element = mount({ columns: "To Do,In Progress,In Review,Done" });
      getBoardData.emit(board([item({ Id: "1" })]));
      await flush();

      expect(columnNames(element)).toEqual([
        "To Do",
        "In Progress",
        "In Review",
        "Done"
      ]);
    });

    it("keeps a configured column visible when it has no records", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1", Status__c: "To Do" })]));
      await flush();

      const done = element.shadowRoot.querySelector('[data-column="Done"]');
      expect(done).not.toBeNull();
      expect(done.querySelector(".col-empty")).not.toBeNull();
    });
  });

  describe("records the columns do not account for", () => {
    it("puts an Unspecified status in its own region, never in a column", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({ Id: "1", Status__c: "To Do" }),
          item({ Id: "2", External_Key__c: "DOPP-9", Status__c: "Unspecified" })
        ])
      );
      await flush();

      const outside = element.shadowRoot.querySelector(
        '[data-region="outside"]'
      );
      expect(outside).not.toBeNull();
      expect(outside.querySelectorAll("c-work-item-card")).toHaveLength(1);

      // It must not have been bucketed into To Do, which would read as a workflow stage.
      const toDo = element.shadowRoot.querySelector('[data-column="To Do"]');
      expect(toDo.querySelectorAll("c-work-item-card")).toHaveLength(1);
    });

    it("surfaces a status that is simply not configured rather than dropping it", async () => {
      const element = mount({ columns: "To Do,Done" });
      getBoardData.emit(board([item({ Id: "1", Status__c: "In Progress" })]));
      await flush();

      // Silently losing records when a column is removed would be worse than an odd region.
      const outside = element.shadowRoot.querySelector(
        '[data-region="outside"]'
      );
      expect(outside).not.toBeNull();
      expect(outside.querySelectorAll("c-work-item-card")).toHaveLength(1);
    });
  });

  describe("card rendering", () => {
    it("renders an Unspecified type with no badge at all", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1", Type__c: "Unspecified" })]));
      await flush();

      const card = cards(element)[0];
      expect(card.shadowRoot.querySelector(".badge")).toBeNull();
      // Still a readable card, not a damaged one.
      expect(card.shadowRoot.querySelector(".heading").textContent).toBe(
        "Reconcile the nightly Jira pull"
      );
    });

    it("heads the card with the title and demotes the key beside the number", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1" })]));
      await flush();

      const card = cards(element)[0];
      expect(card.shadowRoot.querySelector("h3.heading").textContent).toBe(
        "Reconcile the nightly Jira pull"
      );
      expect(card.shadowRoot.querySelector(".num").textContent).toBe(
        "WI-0000 · DOPP-0"
      );
    });

    it("stands the key in as the heading when no title has synced", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1", Title__c: null })]));
      await flush();

      const heading = cards(element)[0].shadowRoot.querySelector("h3.heading");
      expect(heading.textContent).toBe("DOPP-0");
      expect(heading.className).toContain("heading-fallback");
      // Not printed twice: the identity line carries the auto number alone.
      expect(
        cards(element)[0].shadowRoot.querySelector(".num").textContent
      ).toBe("WI-0000");
    });

    it("renders a known type with a badge", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1", Type__c: "Bug" })]));
      await flush();

      expect(
        cards(element)[0].shadowRoot.querySelector(".badge").textContent
      ).toBe("Bug");
    });

    it("flags a record that is not reconciled with Jira", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1", Sync_Status__c: "Pending" })]));
      await flush();

      const flag = cards(element)[0].shadowRoot.querySelector(".sync-flag");
      expect(flag).not.toBeNull();
      expect(flag.textContent).toBe("Pending");
    });

    it("shows no sync flag on a reconciled record", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1", Sync_Status__c: "Synced" })]));
      await flush();

      expect(
        cards(element)[0].shadowRoot.querySelector(".sync-flag")
      ).toBeNull();
    });
  });

  describe("hierarchy", () => {
    it("nests a child under its parent when both sit in one column", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({ Id: "p1", External_Key__c: "DOPP-16", Status__c: "To Do" }),
          item({
            Id: "c1",
            External_Key__c: "DOPP-17",
            Status__c: "To Do",
            Parent_Work_Item__c: "p1"
          })
        ])
      );
      await flush();

      const column = element.shadowRoot.querySelector('[data-column="To Do"]');
      const nested = column.querySelector(".children");
      expect(nested).not.toBeNull();
      expect(nested.querySelectorAll("c-work-item-card")).toHaveLength(1);
    });

    it("leaves a child in its own column when it differs from the parent", async () => {
      // The live data does exactly this: a To Do epic with In Progress children. Nesting
      // there would put an In Progress card under a To Do heading.
      const element = mount();
      getBoardData.emit(
        board([
          item({ Id: "p1", External_Key__c: "DOPP-16", Status__c: "To Do" }),
          item({
            Id: "c1",
            External_Key__c: "DOPP-17",
            Status__c: "In Progress",
            Parent_Work_Item__c: "p1"
          })
        ])
      );
      await flush();

      const inProgress = element.shadowRoot.querySelector(
        '[data-column="In Progress"]'
      );
      expect(inProgress.querySelectorAll("c-work-item-card")).toHaveLength(1);
      const note = inProgress
        .querySelector("c-work-item-card")
        .shadowRoot.querySelector(".parent-note");
      expect(note.textContent).toBe("Child of DOPP-16");
    });

    it("renders an orphan child without breaking", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({
            Id: "c1",
            External_Key__c: "DOPP-17",
            Status__c: "To Do",
            Parent_Work_Item__c: "missing-parent"
          })
        ])
      );
      await flush();

      const card = cards(element)[0];
      expect(card).not.toBeNull();
      expect(card.shadowRoot.querySelector(".parent-note").textContent).toBe(
        "Parent is not on this board"
      );
    });
  });

  describe("states", () => {
    it("explains an empty board rather than rendering nothing", async () => {
      const element = mount();
      getBoardData.emit(board([]));
      await flush();

      const empty = element.shadowRoot.querySelector('[data-state="empty"]');
      expect(empty).not.toBeNull();
      expect(empty.textContent).toContain("No work items yet");
    });

    it("explains a failure rather than rendering nothing", async () => {
      const element = mount();
      // The adapter's first argument is the error BODY; it wraps it as { body, status,
      // statusText } the way a real wire failure arrives.
      getBoardData.error({ message: "Access denied" }, 400, "Bad Request");
      await flush();

      const error = element.shadowRoot.querySelector('[data-state="error"]');
      expect(error).not.toBeNull();
      expect(error.textContent).toContain("Access denied");
      expect(
        element.shadowRoot.querySelector('[data-state="ready"]')
      ).toBeNull();
    });

    it("reads an error delivered as a list of messages", async () => {
      const element = mount();
      getBoardData.error(
        [{ message: "First problem" }, { message: "Second problem" }],
        400,
        "Bad Request"
      );
      await flush();

      const error = element.shadowRoot.querySelector('[data-state="error"]');
      expect(error.textContent).toContain("First problem");
      expect(error.textContent).toContain("Second problem");
    });

    it("shows how fresh the data is", async () => {
      const element = mount();
      getBoardData.emit(board([item({ Id: "1" })]));
      await flush();

      expect(
        element.shadowRoot.querySelector(".freshness").textContent
      ).toContain("Last synced");
    });
  });

  describe("status change", () => {
    async function openDetail(element) {
      getBoardData.emit(board([item({ Id: "w1", Status__c: "To Do" })]));
      await flush();
      cards(element)[0].dispatchEvent(
        new CustomEvent("select", { detail: { id: "w1" } })
      );
      await flush();
    }

    it("offers only configured statuses other than the current one", async () => {
      const element = mount();
      await openDetail(element);

      const options = Array.from(
        element.shadowRoot.querySelectorAll(".status-btn")
      ).map((btn) => btn.dataset.status);
      // Driven by the same configuration as the columns, so an unconfigured status such as
      // the unreachable In Review can never be offered.
      expect(options).toEqual(["In Progress", "Done"]);
      expect(options).not.toContain("To Do");
    });

    it("sends the change to apex and refreshes the board", async () => {
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message:
          "Saved in Salesforce. The Jira update is running in the background."
      });
      const element = mount();
      await openDetail(element);

      element.shadowRoot.querySelector('[data-status="Done"]').click();
      await flush();
      await flush();

      expect(changeStatus).toHaveBeenCalledWith({
        workItemId: "w1",
        newStatus: "Done"
      });
      expect(refreshApex).toHaveBeenCalled();
    });

    it("says the push is asynchronous instead of claiming Jira agreed", async () => {
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message:
          "Saved in Salesforce. The Jira update is running in the background."
      });
      const element = mount();
      await openDetail(element);

      element.shadowRoot.querySelector('[data-status="Done"]').click();
      await flush();
      await flush();

      const note = element.shadowRoot.querySelector('[data-note="ok"]');
      expect(note.textContent).toContain("background");
      expect(note.textContent).toContain("Pending");
    });

    it("reports a failed change instead of failing silently", async () => {
      changeStatus.mockRejectedValue({
        body: { message: "That work item is not available to you." }
      });
      const element = mount();
      await openDetail(element);

      element.shadowRoot.querySelector('[data-status="Done"]').click();
      await flush();
      await flush();

      expect(
        element.shadowRoot.querySelector('[data-note="error"]').textContent
      ).toContain("not available");
    });
  });

  // Build 08 gate. Each rendered state is held to sa11y's rule set on its own: a violation that
  // only exists while the detail panel is open, or only in the error state, would pass a check
  // of the plain board.
  describe("accessibility", () => {
    // The one known violation, pinned exactly rather than waived. Every card on the board is an
    // <article role="button">, which axe rejects (aria-allowed-role) and which also flattens
    // the heading inside it for a screen reader. Not patched here: a <div role="button"> would
    // satisfy the rule and keep the flattened heading. Build 08 step 7 replaces the clickable
    // card with a disclosure button in the card header, and this list must then be empty.
    const KNOWN = ["aria-allowed-role"];

    const busyBoard = () =>
      board([
        item({ Id: "p1", External_Key__c: "DOPP-16", Status__c: "To Do" }),
        item({
          Id: "c1",
          External_Key__c: "DOPP-17",
          Status__c: "To Do",
          Parent_Work_Item__c: "p1"
        }),
        item({
          Id: "c2",
          External_Key__c: "DOPP-18",
          Status__c: "In Progress",
          Parent_Work_Item__c: "p1",
          Sync_Status__c: "Pending"
        }),
        item({
          Id: "u1",
          External_Key__c: "DOPP-9",
          Status__c: "Unspecified",
          Type__c: "Unspecified",
          Description__c: "Has a description"
        })
      ]);

    async function selectFirst(element) {
      cards(element)[0].dispatchEvent(
        new CustomEvent("select", { detail: { id: "p1" } })
      );
      await flush();
    }

    it("is accessible while loading", async () => {
      await expect(mount()).toBeAccessible();
    });

    it("has no violation but the known one with cards, nesting, a sync flag and the outside region", async () => {
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await expect(element).toHaveOnlyKnownA11yViolations(KNOWN);
    });

    it("has no violation but the known one with the detail panel open", async () => {
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await selectFirst(element);
      await expect(element).toHaveOnlyKnownA11yViolations(KNOWN);
    });

    it("has no violation but the known one after a status change is reported", async () => {
      changeStatus.mockResolvedValue({
        workItemId: "p1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message: "Saved in Salesforce."
      });
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await selectFirst(element);
      element.shadowRoot.querySelector('[data-status="Done"]').click();
      await flush();
      await flush();
      await expect(element).toHaveOnlyKnownA11yViolations(KNOWN);
    });

    it("has no violation but the known one when a status change fails", async () => {
      changeStatus.mockRejectedValue({ body: { message: "Not available." } });
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await selectFirst(element);
      element.shadowRoot.querySelector('[data-status="Done"]').click();
      await flush();
      await flush();
      await expect(element).toHaveOnlyKnownA11yViolations(KNOWN);
    });

    it("is accessible when empty", async () => {
      const element = mount();
      getBoardData.emit(board([]));
      await flush();
      await expect(element).toBeAccessible();
    });

    it("is accessible when the board fails to load", async () => {
      const element = mount();
      getBoardData.error({ message: "Access denied" }, 400, "Bad Request");
      await flush();
      await expect(element).toBeAccessible();
    });
  });
});
