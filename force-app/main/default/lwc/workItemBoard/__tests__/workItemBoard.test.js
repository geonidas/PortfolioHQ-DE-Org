import { createElement } from "lwc";
import WorkItemBoard from "c/workItemBoard";
import getBoardData from "@salesforce/apex/WorkItemBoardController.getBoardData";
import changeStatus from "@salesforce/apex/WorkItemBoardController.changeStatus";
import { refreshApex } from "@salesforce/apex";
import { subscribe, unsubscribe } from "lightning/empApi";

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

/**
 * The controller's card payload - WorkItemBoardController.BoardCard - not an SObject. Since build
 * 08 step 5 both boards receive cards with the same property names for the same facts.
 */
function item(overrides) {
  return Object.assign(
    {
      id: "",
      recordNumber: "WI-0000",
      title: "Reconcile the nightly Jira pull",
      externalKey: "DOPP-0",
      status: "To Do",
      type: "Story",
      syncStatus: "Synced",
      syncError: null,
      storyPoints: null,
      description: null,
      parentId: null,
      projectLabel: "Portfolio HQ",
      sourceLabel: "Jira",
      accentToken: "accent-1",
      condensesIntoEpic: true,
      supportsStartDate: true,
      createdAt: "2026-09-08T21:59:09.000Z",
      startDate: null,
      dueDate: null
    },
    overrides
  );
}

function board(items) {
  return {
    items,
    itemCount: items.length,
    epics: [],
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
  return Array.from(element.shadowRoot.querySelectorAll("c-board-card"));
}

const toolbar = (element) =>
  element.shadowRoot.querySelector("c-board-toolbar");
async function choose(element, name, value) {
  const control = toolbar(element).shadowRoot.querySelector(
    `select[data-filter="${name}"]`
  );
  control.value = value;
  control.dispatchEvent(new CustomEvent("change"));
  await flush();
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
      getBoardData.emit(board([item({ id: "1", status: "Backlog" })]));
      await flush();

      // The point of the configuration: no status string is baked into the markup, so a
      // board can name its columns anything the org uses.
      expect(columnNames(element)).toEqual(["Backlog", "Doing"]);
      expect(columnNames(element)).not.toContain("To Do");
    });

    it("falls back to the default three when nothing is configured", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "1" })]));
      await flush();

      expect(columnNames(element)).toEqual(["To Do", "In Progress", "Done"]);
    });

    it("adds a column from configuration alone, with no code change", async () => {
      // In Review is unreachable in the live Jira board, which is exactly why it must be
      // addable later without touching this component.
      const element = mount({ columns: "To Do,In Progress,In Review,Done" });
      getBoardData.emit(board([item({ id: "1" })]));
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
      getBoardData.emit(board([item({ id: "1", status: "To Do" })]));
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
          item({ id: "1", status: "To Do" }),
          item({ id: "2", externalKey: "DOPP-9", status: "Unspecified" })
        ])
      );
      await flush();

      const outside = element.shadowRoot.querySelector(
        '[data-region="outside"]'
      );
      expect(outside).not.toBeNull();
      expect(outside.querySelectorAll("c-board-card")).toHaveLength(1);

      // It must not have been bucketed into To Do, which would read as a workflow stage.
      const toDo = element.shadowRoot.querySelector('[data-column="To Do"]');
      expect(toDo.querySelectorAll("c-board-card")).toHaveLength(1);
    });

    it("surfaces a status that is simply not configured rather than dropping it", async () => {
      const element = mount({ columns: "To Do,Done" });
      getBoardData.emit(board([item({ id: "1", status: "In Progress" })]));
      await flush();

      // Silently losing records when a column is removed would be worse than an odd region.
      const outside = element.shadowRoot.querySelector(
        '[data-region="outside"]'
      );
      expect(outside).not.toBeNull();
      expect(outside.querySelectorAll("c-board-card")).toHaveLength(1);
    });
  });

  describe("card rendering", () => {
    it("renders an Unspecified type with no badge at all", async () => {
      const element = mount();
      // The controller sends null for a type with no mapping, never the sentinel itself.
      getBoardData.emit(board([item({ id: "1", type: null })]));
      await flush();

      const card = cards(element)[0];
      expect(card.shadowRoot.querySelector("[data-type]")).toBeNull();
      // Still a readable card, not a damaged one.
      expect(card.shadowRoot.querySelector(".heading").textContent).toBe(
        "Reconcile the nightly Jira pull"
      );
    });

    it("heads the card with the title and demotes the key beside the number", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "1" })]));
      await flush();

      const card = cards(element)[0];
      expect(card.shadowRoot.querySelector("h3 .heading").textContent).toBe(
        "Reconcile the nightly Jira pull"
      );
      expect(
        card.shadowRoot.querySelector("[data-meta] .assistive").textContent
      ).toBe("Jira, WI-0000, DOPP-0, Story");
    });

    it("stands the key in as the heading when no title has synced", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "1", title: null })]));
      await flush();

      const heading = cards(element)[0].shadowRoot.querySelector("h3 .heading");
      expect(heading.textContent).toBe("DOPP-0");
      expect(heading.className).toContain("is-fallback");
      // Not printed twice: the identity line carries the auto number alone.
      expect(
        Array.from(
          cards(element)[0].shadowRoot.querySelectorAll("[data-ids] .id")
        ).map((id) => id.textContent)
      ).toEqual(["WI-0000"]);
    });

    it("renders a known type with a badge", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "1", type: "Bug" })]));
      await flush();

      expect(
        cards(element)[0].shadowRoot.querySelector("[data-type]").textContent
      ).toBe("Bug");
    });

    it("flags a record that is not reconciled with its source", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "1", syncStatus: "Pending" })]));
      await flush();

      const flag = cards(element)[0].shadowRoot.querySelector("[data-sync]");
      expect(flag).not.toBeNull();
      expect(flag.textContent).toBe("Pending");
    });

    it("shows no sync flag on a reconciled record", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "1", syncStatus: "Synced" })]));
      await flush();

      expect(
        cards(element)[0].shadowRoot.querySelector("[data-sync]")
      ).toBeNull();
    });
  });

  describe("hierarchy", () => {
    it("nests a child under its parent when both sit in one column", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({ id: "p1", externalKey: "DOPP-16", status: "To Do" }),
          item({
            id: "c1",
            externalKey: "DOPP-17",
            status: "To Do",
            parentId: "p1"
          })
        ])
      );
      await flush();

      const column = element.shadowRoot.querySelector('[data-column="To Do"]');
      const nested = column.querySelector(".children");
      expect(nested).not.toBeNull();
      expect(nested.querySelectorAll("c-board-card")).toHaveLength(1);
    });

    it("leaves a child in its own column when it differs from the parent", async () => {
      // The live data does exactly this: a To Do epic with In Progress children. Nesting
      // there would put an In Progress card under a To Do heading.
      const element = mount();
      getBoardData.emit(
        board([
          item({ id: "p1", externalKey: "DOPP-16", status: "To Do" }),
          item({
            id: "c1",
            externalKey: "DOPP-17",
            status: "In Progress",
            parentId: "p1"
          })
        ])
      );
      await flush();

      const inProgress = element.shadowRoot.querySelector(
        '[data-column="In Progress"]'
      );
      expect(inProgress.querySelectorAll("c-board-card")).toHaveLength(1);
      const note = inProgress
        .querySelector("c-board-card")
        .shadowRoot.querySelector(".parent-note");
      expect(note.textContent).toBe("Child of DOPP-16");
    });

    it("renders an orphan child without breaking", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({
            id: "c1",
            externalKey: "DOPP-17",
            status: "To Do",
            parentId: "missing-parent"
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
      getBoardData.emit(board([item({ id: "1" })]));
      await flush();

      expect(
        element.shadowRoot.querySelector(".freshness").textContent
      ).toContain("Last synced");
    });
  });

  describe("status change", () => {
    async function openDetail(element) {
      getBoardData.emit(board([item({ id: "w1", status: "To Do" })]));
      await flush();
      cards(element)[0].dispatchEvent(
        new CustomEvent("select", { detail: { key: "w1" } })
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
    // Step 1 pinned one known violation here, aria-allowed-role, for the old card's
    // <article role="button">. Step 6's shared card puts a real button inside its heading
    // instead, the pinned matcher failed on the fix as it was built to, and the pin is gone.

    const busyBoard = () =>
      board([
        item({ id: "p1", externalKey: "DOPP-16", status: "To Do" }),
        item({
          id: "c1",
          externalKey: "DOPP-17",
          status: "To Do",
          parentId: "p1"
        }),
        item({
          id: "c2",
          externalKey: "DOPP-18",
          status: "In Progress",
          parentId: "p1",
          syncStatus: "Pending"
        }),
        item({
          id: "u1",
          externalKey: "DOPP-9",
          status: "Unspecified",
          type: null,
          description: "Has a description"
        })
      ]);

    async function selectFirst(element) {
      cards(element)[0].dispatchEvent(
        new CustomEvent("select", { detail: { key: "p1" } })
      );
      await flush();
    }

    it("is accessible while loading", async () => {
      await expect(mount()).toBeAccessible();
    });

    it("is accessible with cards, nesting, a sync flag and the outside region", async () => {
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await expect(element).toBeAccessible();
    });

    it("is accessible with the detail panel open", async () => {
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await selectFirst(element);
      await expect(element).toBeAccessible();
    });

    it("is accessible after a status change is reported", async () => {
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
      await expect(element).toBeAccessible();
    });

    it("is accessible when a status change fails", async () => {
      changeStatus.mockRejectedValue({ body: { message: "Not available." } });
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await selectFirst(element);
      element.shadowRoot.querySelector('[data-status="Done"]').click();
      await flush();
      await flush();
      await expect(element).toBeAccessible();
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

  // Build 08 step 6. The shared toolbar, card and epic view.
  describe("toolbar, cards and the epic view", () => {
    const mixed = () => {
      const data = board([
        item({
          id: "e1",
          recordNumber: "WI-0000",
          type: "Epic",
          status: "In Progress"
        }),
        item({
          id: "s1",
          recordNumber: "WI-0003",
          parentId: "e1",
          status: "To Do"
        }),
        item({
          id: "a1",
          recordNumber: "WI-0015",
          title: "Deep Work",
          externalKey: null,
          type: "Book",
          status: "To Do",
          sourceLabel: "Asana",
          accentToken: "accent-2",
          condensesIntoEpic: false,
          supportsStartDate: false
        })
      ]);
      data.epics = [
        {
          id: "e1",
          recordNumber: "WI-0000",
          title: "Integration app",
          status: "In Progress",
          totalChildren: 1,
          completedChildren: 0,
          sourceLabel: "Jira",
          accentToken: "accent-1"
        }
      ];
      return data;
    };
    const total = (el) => el.shadowRoot.querySelector(".total").textContent;

    it("opens the detail panel from the button in a card's heading", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "w1" })]));
      await flush();

      cards(element)[0].shadowRoot.querySelector("button[data-select]").click();
      await flush();

      expect(
        element.shadowRoot.querySelector('[data-region="detail"]')
      ).not.toBeNull();
    });

    it("shows the Epics view from the payload's epics, with flat work passing through", async () => {
      const element = mount();
      getBoardData.emit(mixed());
      await flush();
      expect(total(element)).toBe("3 items");

      await choose(element, "view", "epics");

      const epicCards =
        element.shadowRoot.querySelectorAll("c-board-epic-card");
      expect(epicCards).toHaveLength(1);
      expect(epicCards[0].shadowRoot.querySelector(".count").textContent).toBe(
        "0 of 1 done"
      );
      // The flat source's card keeps its own column; the story rolls up into the epic.
      expect(
        cards(element).map(
          (c) => c.shadowRoot.querySelector(".heading").textContent
        )
      ).toEqual(["Deep Work"]);
      // Two kinds of card, counted as what they are.
      expect(total(element)).toBe("1 epic, 1 item");
    });

    it("filters both views by source", async () => {
      const element = mount();
      getBoardData.emit(mixed());
      await flush();

      await choose(element, "source", "Asana");
      expect(cards(element)).toHaveLength(1);
      expect(total(element)).toBe("1 item");

      await choose(element, "view", "epics");
      expect(
        element.shadowRoot.querySelectorAll("c-board-epic-card")
      ).toHaveLength(0);
      expect(cards(element)).toHaveLength(1);
    });

    it("says Overdue on this board, where the public one shows only dates", async () => {
      const element = mount();
      getBoardData.emit(
        board([item({ id: "1", dueDate: "2020-01-01", status: "To Do" })])
      );
      await flush();

      expect(
        cards(element)[0].shadowRoot.querySelector("[data-date='overdue']")
      ).not.toBeNull();
    });

    it("gives a record with no remote record no sync chip, and says why in the panel", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "c1", syncStatus: null })]));
      await flush();

      expect(
        cards(element)[0].shadowRoot.querySelector("[data-sync]")
      ).toBeNull();

      cards(element)[0].dispatchEvent(
        new CustomEvent("select", { detail: { key: "c1" } })
      );
      await flush();
      expect(
        element.shadowRoot.querySelector('[data-region="detail"]').textContent
      ).toContain("No remote record");
    });

    it("is accessible in the Epics view with a source chosen", async () => {
      const element = mount();
      getBoardData.emit(mixed());
      await flush();
      await choose(element, "view", "epics");
      await choose(element, "source", "Jira");
      await expect(element).toBeAccessible();
    });
  });

  // Build 08 step 5. Change Data Capture on Work_Item__c, subscribed by this container alone.
  describe("live updates", () => {
    afterEach(() => {
      jest.useRealTimers();
    });

    it("subscribes to the work item change channel when it connects", async () => {
      mount();
      await flush();

      expect(subscribe).toHaveBeenCalledTimes(1);
      expect(subscribe.mock.calls[0][0]).toBe("/data/Work_Item__ChangeEvent");
      // -1: new events only. Replaying history would refresh for changes already on screen.
      expect(subscribe.mock.calls[0][1]).toBe(-1);
    });

    it("says it is live once subscribed", async () => {
      const element = mount();
      getBoardData.emit(board([item({ id: "1" })]));
      await flush();
      await flush();

      expect(
        element.shadowRoot.querySelector("[data-live]").textContent
      ).toContain("Live");
    });

    it("refreshes once after a burst of changes settles", async () => {
      jest.useFakeTimers();
      mount();
      getBoardData.emit(board([item({ id: "1" })]));
      await flush();
      const onMessage = subscribe.mock.calls[0][2];

      // An edit, then the sync's own write-back moments later: two events, one refresh.
      onMessage({ data: { payload: {} } });
      jest.advanceTimersByTime(500);
      onMessage({ data: { payload: {} } });
      expect(refreshApex).not.toHaveBeenCalled();

      jest.advanceTimersByTime(1500);
      expect(refreshApex).toHaveBeenCalledTimes(1);
    });

    it("unsubscribes when it disconnects", async () => {
      const subscription = { channel: "/data/Work_Item__ChangeEvent", id: 7 };
      subscribe.mockResolvedValueOnce(subscription);
      const element = mount();
      await flush();

      document.body.removeChild(element);

      expect(unsubscribe).toHaveBeenCalledWith(subscription);
    });

    it("does not refresh after it has disconnected", async () => {
      jest.useFakeTimers();
      const element = mount();
      getBoardData.emit(board([item({ id: "1" })]));
      await flush();
      const onMessage = subscribe.mock.calls[0][2];

      onMessage({ data: { payload: {} } });
      document.body.removeChild(element);
      jest.advanceTimersByTime(5000);

      expect(refreshApex).not.toHaveBeenCalled();
    });
  });
});
