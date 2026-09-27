import { createElement } from "lwc";
import WorkItemBoard from "c/workItemBoard";
import getBoardData from "@salesforce/apex/WorkItemBoardController.getBoardData";
import changeStatus from "@salesforce/apex/WorkItemBoardController.changeStatus";
import saveDetails from "@salesforce/apex/WorkItemBoardController.saveDetails";
import retryPush from "@salesforce/apex/WorkItemBoardController.retryPush";
import featureEpic from "@salesforce/apex/WorkItemBoardController.featureEpic";
import unfeatureEpic from "@salesforce/apex/WorkItemBoardController.unfeatureEpic";
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
  "@salesforce/apex/WorkItemBoardController.saveDetails",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/WorkItemBoardController.retryPush",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/WorkItemBoardController.featureEpic",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/WorkItemBoardController.unfeatureEpic",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
// The record link: GenerateUrl hands back a URL naming the record, Navigate is recorded.
const mockNavigate = jest.fn();
jest.mock("lightning/navigation", () => {
  const Navigate = Symbol("Navigate");
  const GenerateUrl = Symbol("GenerateUrl");
  const NavigationMixin = (Base) =>
    class extends Base {
      [Navigate](pageReference) {
        mockNavigate(pageReference);
      }
      [GenerateUrl](pageReference) {
        return Promise.resolve(`/r/${pageReference.attributes.recordId}`);
      }
    };
  NavigationMixin.Navigate = Navigate;
  NavigationMixin.GenerateUrl = GenerateUrl;
  return { NavigationMixin };
});
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
      dueDate: null,
      // Build 09 step 5.
      priority: null,
      priorityRank: null,
      supportsPriority: false
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
    lastSyncedAt: "2026-09-13T05:20:07.000Z",
    canOpenRecord: false,
    titleMaxLength: 255
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
const cardFor = (element, key) =>
  element.shadowRoot.querySelector(`c-board-card[data-key="${key}"]`);
const inCard = (element, key, selector) =>
  cardFor(element, key).shadowRoot.querySelector(selector);
/** Opens a card the way a user does: its header. */
async function openCard(element, key) {
  inCard(element, key, "[data-disclosure]").click();
  await flush();
}
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

  // Build 08 step 7: the top panel is gone. A card opens in place, and the open card holds the
  // Move to buttons, the editor and the record link - because this board grants them.
  describe("the open card", () => {
    const one = () => board([item({ id: "w1", status: "To Do" })]);

    it("opens in place, one card at a time, and has no panel above the board", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({ id: "w1", status: "To Do" }),
          item({ id: "w2", status: "Done" })
        ])
      );
      await flush();
      const open = () =>
        ["w1", "w2"].map((key) =>
          inCard(element, key, "[data-disclosure]").getAttribute(
            "aria-expanded"
          )
        );

      await openCard(element, "w1");
      expect(open()).toStrictEqual(["true", "false"]);
      await openCard(element, "w2");
      expect(open()).toStrictEqual(["false", "true"]);
      expect(
        element.shadowRoot.querySelector('[data-region="detail"]')
      ).toBeNull();
    });

    it("offers only configured statuses other than the current one", async () => {
      const element = mount();
      getBoardData.emit(one());
      await flush();
      await openCard(element, "w1");

      const options = Array.from(
        cardFor(element, "w1").shadowRoot.querySelectorAll("[data-move]")
      ).map((btn) => btn.dataset.move);
      // Driven by the same configuration as the columns, so an unconfigured status such as
      // the unreachable In Review can never be offered.
      expect(options).toStrictEqual(["In Progress", "Done"]);
    });

    it("sends a move to apex, refreshes, and says the source has not confirmed yet", async () => {
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message:
          "Saved in Salesforce. The Jira update is running in the background."
      });
      const element = mount();
      getBoardData.emit(one());
      await flush();
      await openCard(element, "w1");

      inCard(element, "w1", '[data-move="Done"]').click();
      await flush();
      await flush();

      expect(changeStatus).toHaveBeenCalledWith({
        workItemId: "w1",
        newStatus: "Done"
      });
      expect(refreshApex).toHaveBeenCalled();
      const note = inCard(element, "w1", "[data-feedback]").textContent;
      expect(note).toContain("background");
      expect(note).toContain("stays Pending until Jira confirms");
    });

    it("follows a moved card to its new column with focus", async () => {
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message: "Saved."
      });
      refreshApex.mockImplementationOnce(() => {
        getBoardData.emit(board([item({ id: "w1", status: "Done" })]));
        return Promise.resolve();
      });
      const element = mount();
      getBoardData.emit(one());
      await flush();
      await openCard(element, "w1");

      inCard(element, "w1", '[data-move="Done"]').click();
      await flush();
      await flush();
      await flush();

      const moved = cardFor(element, "w1");
      expect(moved.closest("[data-column]").dataset.column).toBe("Done");
      // Still open in its new place, with focus on its header.
      const header = moved.shadowRoot.querySelector("[data-disclosure]");
      expect(header.getAttribute("aria-expanded")).toBe("true");
      expect(moved.shadowRoot.activeElement).toBe(header);
    });

    it("reports a failed move instead of failing silently", async () => {
      changeStatus.mockRejectedValue({
        body: { message: "That work item is not available to you." }
      });
      const element = mount();
      getBoardData.emit(one());
      await flush();
      await openCard(element, "w1");

      inCard(element, "w1", '[data-move="Done"]').click();
      await flush();
      await flush();

      expect(inCard(element, "w1", "[data-feedback]").textContent).toContain(
        "not available"
      );
    });

    it("saves title and dates through saveDetails, and refreshes when it saved", async () => {
      saveDetails.mockResolvedValue({
        workItemId: "w1",
        saved: true,
        pushQueued: true,
        syncStatus: "Pending",
        message:
          "Saved in Salesforce. The Jira update is running in the background.",
        fieldErrors: {}
      });
      const element = mount();
      getBoardData.emit(one());
      await flush();
      await openCard(element, "w1");

      const title = inCard(element, "w1", "[data-field='title']");
      title.value = "Renamed";
      title.dispatchEvent(new CustomEvent("input"));
      const due = inCard(element, "w1", "[data-field='dueDate']");
      due.value = "2026-10-02";
      due.dispatchEvent(new CustomEvent("change"));
      inCard(element, "w1", "form").dispatchEvent(
        new CustomEvent("submit", { cancelable: true })
      );
      await flush();
      await flush();

      // Dates leave as the input's own YYYY-MM-DD strings; no Date is built on the way.
      expect(saveDetails).toHaveBeenCalledWith({
        workItemId: "w1",
        title: "Renamed",
        startDate: "",
        dueDate: "2026-10-02"
      });
      expect(refreshApex).toHaveBeenCalled();
      expect(inCard(element, "w1", "[data-feedback]").textContent).toContain(
        "running in the background"
      );
    });

    it("puts the server's field errors beside their fields and does not refresh", async () => {
      saveDetails.mockResolvedValue({
        workItemId: "w1",
        saved: false,
        syncStatus: "Synced",
        message: "Nothing was saved. Fix the fields marked below.",
        fieldErrors: {
          dueDate:
            "The due date is not a date. Pick one from the calendar, or clear it."
        }
      });
      const element = mount();
      getBoardData.emit(one());
      await flush();
      await openCard(element, "w1");

      inCard(element, "w1", "form").dispatchEvent(
        new CustomEvent("submit", { cancelable: true })
      );
      await flush();
      await flush();

      expect(
        inCard(element, "w1", "[data-error='dueDate']").textContent.trim()
      ).toBe(
        "The due date is not a date. Pick one from the calendar, or clear it."
      );
      expect(refreshApex).not.toHaveBeenCalled();
    });

    it("links to the record only for a user with the custom permission", async () => {
      const element = mount();
      getBoardData.emit(one());
      await flush();
      await openCard(element, "w1");
      await flush();
      expect(inCard(element, "w1", "[data-record-link]")).toBeNull();

      const granted = one();
      granted.canOpenRecord = true;
      getBoardData.emit(granted);
      await flush();
      // Closed, then opened again: the link is made when a card opens.
      await openCard(element, "w1");
      await openCard(element, "w1");
      await flush();

      const link = inCard(element, "w1", "[data-record-link]");
      expect(link.getAttribute("href")).toBe("/r/w1");
      link.dispatchEvent(
        new MouseEvent("click", { button: 0, bubbles: true, cancelable: true })
      );
      expect(mockNavigate).toHaveBeenCalledWith({
        type: "standard__recordPage",
        attributes: {
          recordId: "w1",
          objectApiName: "Work_Item__c",
          actionName: "view"
        }
      });
    });

    it("explains the sync state with the source's label, and the canary says it sends nothing", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({ id: "p1", syncStatus: "Pending" }),
          item({ id: "c1", syncStatus: null, status: "In Progress" })
        ])
      );
      await flush();

      await openCard(element, "p1");
      expect(inCard(element, "p1", "[data-sync-note]").textContent).toBe(
        "Pending: saved in Salesforce, and the Jira update is running."
      );

      await openCard(element, "c1");
      expect(inCard(element, "c1", "[data-sync]")).toBeNull();
      expect(inCard(element, "c1", "[data-sync-note]").textContent).toBe(
        "Not linked to a Jira record, so nothing is sent."
      );
    });

    it("names the parent by number and title", async () => {
      const element = mount();
      getBoardData.emit(
        board([
          item({
            id: "p1",
            recordNumber: "WI-0002",
            title: "Public board",
            status: "Done"
          }),
          item({
            id: "c1",
            recordNumber: "WI-0003",
            parentId: "p1",
            status: "To Do"
          }),
          item({
            id: "o1",
            recordNumber: "WI-0004",
            parentId: "gone",
            status: "To Do"
          })
        ])
      );
      await flush();

      await openCard(element, "c1");
      expect(inCard(element, "c1", "[data-parent]").textContent).toBe(
        "WI-0002 Public board"
      );
      await openCard(element, "o1");
      expect(inCard(element, "o1", "[data-parent]").textContent).toBe(
        "A work item that is not on this board"
      );
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

    it("is accessible while loading", async () => {
      await expect(mount()).toBeAccessible();
    });

    it("is accessible with cards, nesting, a sync flag and the outside region", async () => {
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await expect(element).toBeAccessible();
    });

    it("is accessible with a card open, editor and link included", async () => {
      const element = mount();
      const data = busyBoard();
      data.canOpenRecord = true;
      getBoardData.emit(data);
      await flush();
      await openCard(element, "p1");
      await flush();
      await expect(element).toBeAccessible();
    });

    it("is accessible after a move is reported", async () => {
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
      await openCard(element, "p1");
      inCard(element, "p1", '[data-move="Done"]').click();
      await flush();
      await flush();
      await expect(element).toBeAccessible();
    });

    it("is accessible when a save is refused field by field", async () => {
      saveDetails.mockResolvedValue({
        workItemId: "p1",
        saved: false,
        message: "Nothing was saved. Fix the fields marked below.",
        fieldErrors: { title: "A title is required. Type one before saving." }
      });
      const element = mount();
      getBoardData.emit(busyBoard());
      await flush();
      await openCard(element, "p1");
      inCard(element, "p1", "form").dispatchEvent(
        new CustomEvent("submit", { cancelable: true })
      );
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

    it("opens an epic card in the Epics view, with its record link when granted", async () => {
      const element = mount();
      const data = mixed();
      data.canOpenRecord = true;
      getBoardData.emit(data);
      await flush();
      await choose(element, "view", "epics");

      const epicCard = element.shadowRoot.querySelector("c-board-epic-card");
      epicCard.shadowRoot.querySelector("[data-disclosure]").click();
      await flush();
      await flush();

      expect(
        epicCard.shadowRoot
          .querySelector("[data-disclosure]")
          .getAttribute("aria-expanded")
      ).toBe("true");
      // Keyed "epic-" and its id, and the link names the epic's own record.
      expect(
        epicCard.shadowRoot
          .querySelector("[data-record-link]")
          .getAttribute("href")
      ).toBe("/r/e1");
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

  // Build 08 step 8. Drag-and-drop with a fine pointer in the landscape layout, and Retry.
  describe("drag-and-drop and retry", () => {
    const FINE = "(pointer: fine)";
    const PORTRAIT = "(orientation: portrait) and (max-width: 700px)";
    let media;

    /** A stand-in for window.matchMedia whose answers a test can change, firing listeners. */
    function mockMedia({ fine, portrait }) {
      media = { [FINE]: fine, [PORTRAIT]: portrait, listeners: [] };
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
    function changeMedia(values) {
      Object.assign(media, values);
      media.listeners.forEach((listener) => listener());
    }
    function dragEvent(type) {
      const event = new CustomEvent(type, { bubbles: true, cancelable: true });
      Object.defineProperty(event, "dataTransfer", {
        value: {
          setData() {},
          setDragImage() {},
          effectAllowed: "",
          dropEffect: ""
        }
      });
      return event;
    }
    const surface = (element, key) =>
      inCard(element, key, "[data-drag-surface]");
    const column = (element, status) =>
      element.shadowRoot.querySelector(`[data-column="${status}"]`);
    async function dragTo(element, key, status) {
      surface(element, key).dispatchEvent(dragEvent("dragstart"));
      await flush();
      const over = dragEvent("dragover");
      column(element, status).dispatchEvent(over);
      const drop = dragEvent("drop");
      column(element, status).dispatchEvent(drop);
      surface(element, key).dispatchEvent(dragEvent("dragend"));
      await flush();
      await flush();
      return over;
    }
    const twoColumns = () =>
      board([
        item({ id: "w1", recordNumber: "WI-0001", status: "To Do" }),
        item({ id: "w2", recordNumber: "WI-0002", status: "Done" })
      ]);

    afterEach(() => {
      delete window.matchMedia;
    });

    it("lets cards be dragged with a fine pointer in the landscape layout", async () => {
      mockMedia({ fine: true, portrait: false });
      const element = mount();
      getBoardData.emit(twoColumns());
      await flush();

      expect(surface(element, "w1").getAttribute("draggable")).toBe("true");
    });

    it("offers no drag with a coarse pointer, or in the portrait layout", async () => {
      mockMedia({ fine: false, portrait: false });
      const coarse = mount();
      getBoardData.emit(twoColumns());
      await flush();
      expect(surface(coarse, "w1").getAttribute("draggable")).toBeNull();
      document.body.removeChild(coarse);

      mockMedia({ fine: true, portrait: true });
      const portrait = mount();
      getBoardData.emit(twoColumns());
      await flush();
      expect(surface(portrait, "w1").getAttribute("draggable")).toBeNull();
      // The Move to buttons are still there: the alternative to dragging, always.
      await openCard(portrait, "w1");
      expect(inCard(portrait, "w1", '[data-move="Done"]')).not.toBeNull();
    });

    it("follows the layout as it changes", async () => {
      mockMedia({ fine: true, portrait: false });
      const element = mount();
      getBoardData.emit(twoColumns());
      await flush();

      changeMedia({ [PORTRAIT]: true });
      await flush();
      expect(surface(element, "w1").getAttribute("draggable")).toBeNull();

      changeMedia({ [PORTRAIT]: false });
      await flush();
      expect(surface(element, "w1").getAttribute("draggable")).toBe("true");
    });

    it("moves a card dropped in another column through changeStatus, and says so", async () => {
      mockMedia({ fine: true, portrait: false });
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message:
          "Saved in Salesforce. The Jira update is running in the background."
      });
      const element = mount();
      getBoardData.emit(twoColumns());
      await flush();

      const over = await dragTo(element, "w1", "Done");

      expect(over.defaultPrevented).toBe(true);
      expect(changeStatus).toHaveBeenCalledWith({
        workItemId: "w1",
        newStatus: "Done"
      });
      expect(refreshApex).toHaveBeenCalled();
      expect(
        element.shadowRoot.querySelector("[data-board-message]").textContent
      ).toContain("WI-0001 moved to Done.");
      expect(element.shadowRoot.querySelector("[data-drop-target]")).toBeNull();
    });

    it("does nothing when a card is dropped in its own column", async () => {
      mockMedia({ fine: true, portrait: false });
      const element = mount();
      getBoardData.emit(twoColumns());
      await flush();

      const over = await dragTo(element, "w1", "To Do");

      // Not a drop target, so the browser shows no drop there at all.
      expect(over.defaultPrevented).toBe(false);
      expect(changeStatus).not.toHaveBeenCalled();
    });

    it("leaves the card where it was, and says why, when the save fails", async () => {
      mockMedia({ fine: true, portrait: false });
      changeStatus.mockRejectedValue({
        body: { message: "That work item is not available to you." }
      });
      const element = mount();
      getBoardData.emit(twoColumns());
      await flush();

      await dragTo(element, "w1", "Done");

      expect(
        cardFor(element, "w1").closest("[data-column]").dataset.column
      ).toBe("To Do");
      expect(refreshApex).not.toHaveBeenCalled();
      const message = element.shadowRoot.querySelector("[data-board-message]");
      expect(message.textContent).toContain("WI-0001 was not moved.");
      expect(message.className).toContain("board-message-error");
    });

    it("moves the dragged record only, never its children", async () => {
      mockMedia({ fine: true, portrait: false });
      changeStatus.mockResolvedValue({
        workItemId: "p1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message: "Saved."
      });
      const element = mount();
      getBoardData.emit(
        board([
          item({ id: "p1", recordNumber: "WI-0001", status: "To Do" }),
          item({
            id: "c1",
            recordNumber: "WI-0002",
            status: "To Do",
            parentId: "p1"
          })
        ])
      );
      await flush();

      await dragTo(element, "p1", "Done");

      expect(changeStatus).toHaveBeenCalledTimes(1);
      expect(changeStatus).toHaveBeenCalledWith({
        workItemId: "p1",
        newStatus: "Done"
      });
    });

    it("sends a failed change again from the open card's Retry", async () => {
      retryPush.mockResolvedValue({
        workItemId: "w1",
        status: "To Do",
        syncStatus: "Pending",
        pushQueued: true,
        message:
          "Sending it to Jira again. The update is running in the background."
      });
      const element = mount();
      getBoardData.emit(
        board([
          item({
            id: "w1",
            syncStatus: "Failed",
            syncError: "Jira returned 503."
          })
        ])
      );
      await flush();
      await openCard(element, "w1");

      inCard(element, "w1", "[data-action='retry']").click();
      await flush();
      await flush();

      expect(retryPush).toHaveBeenCalledWith({ workItemId: "w1" });
      expect(refreshApex).toHaveBeenCalled();
      expect(inCard(element, "w1", "[data-feedback]").textContent).toContain(
        "again"
      );
    });

    it("shows one column at a time in portrait, with arrows and no drag", async () => {
      mockMedia({ fine: true, portrait: true });
      Element.prototype.scrollBy = jest.fn();
      const element = mount();
      getBoardData.emit(twoColumns());
      await flush();
      await flush();

      const layout = element.shadowRoot.querySelector("c-board-columns");
      expect(
        layout.shadowRoot.querySelector("[data-position] .assistive")
          .textContent
      ).toBe("In Progress, 2 of 3");
      expect(
        layout.shadowRoot
          .querySelector('[data-arrow="next"]')
          .getAttribute("aria-label")
      ).toBe("Show Done column");
      expect(surface(element, "w1").getAttribute("draggable")).toBeNull();
      delete Element.prototype.scrollBy;
    });

    it("stops listening to the layout when it disconnects", async () => {
      mockMedia({ fine: true, portrait: false });
      const element = mount();
      await flush();
      expect(media.listeners.length).toBe(2);

      document.body.removeChild(element);

      expect(media.listeners.length).toBe(0);
    });

    it("is accessible with drag on and a drop reported", async () => {
      mockMedia({ fine: true, portrait: false });
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "Done",
        syncStatus: "Pending",
        pushQueued: true,
        message: "Saved."
      });
      const element = mount();
      getBoardData.emit(twoColumns());
      await flush();
      await dragTo(element, "w1", "Done");
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

  describe("priority (build 09)", () => {
    const OPTIONS = [
      { value: "P1", label: "First", rank: 1 },
      { value: "P2", label: "Second", rank: 2 },
      { value: "P3", label: "Third", rank: 3 }
    ];
    const withOptions = (items) =>
      Object.assign(board(items), { priorityOptions: OPTIONS });
    const saveWith = async (element, value) => {
      const control = inCard(element, "w1", "[data-field='priority']");
      control.value = value;
      control.dispatchEvent(new CustomEvent("change"));
      inCard(element, "w1", "form").dispatchEvent(
        new CustomEvent("submit", { cancelable: true })
      );
      await flush();
      await flush();
    };

    beforeEach(() => {
      saveDetails.mockResolvedValue({
        workItemId: "w1",
        saved: true,
        pushQueued: true,
        syncStatus: "Pending",
        message: "Saved.",
        fieldErrors: {}
      });
    });

    it("hands the board's choices to the open card", async () => {
      const element = mount();
      getBoardData.emit(
        withOptions([
          item({
            id: "w1",
            supportsPriority: true,
            priority: "Second",
            priorityRank: 2
          })
        ])
      );
      await flush();
      await openCard(element, "w1");
      const labels = Array.from(
        inCard(element, "w1", "[data-field='priority']").querySelectorAll(
          "option"
        )
      ).map((option) => option.textContent.trim());
      expect(labels).toStrictEqual(["First", "Second", "Third", "No priority"]);
    });

    it("sends the chosen value, and an empty string for No priority", async () => {
      const element = mount();
      getBoardData.emit(
        withOptions([
          item({
            id: "w1",
            supportsPriority: true,
            priority: "Second",
            priorityRank: 2
          })
        ])
      );
      await flush();
      await openCard(element, "w1");

      await saveWith(element, "");
      expect(saveDetails).toHaveBeenLastCalledWith({
        workItemId: "w1",
        title: "Reconcile the nightly Jira pull",
        startDate: "",
        dueDate: "",
        priority: ""
      });
    });

    it("leaves priority out for a card whose source holds none, so Apex leaves it alone", async () => {
      const element = mount();
      getBoardData.emit(
        withOptions([item({ id: "w1", supportsPriority: false })])
      );
      await flush();
      await openCard(element, "w1");
      inCard(element, "w1", "form").dispatchEvent(
        new CustomEvent("submit", { cancelable: true })
      );
      await flush();
      await flush();
      expect("priority" in saveDetails.mock.calls.at(-1)[0]).toBe(false);
    });
  });

  describe("sorting (build 09)", () => {
    const sortBy = async (element, value) => {
      const control = toolbar(element).shadowRoot.querySelector(
        'select[data-filter="sort"]'
      );
      control.value = value;
      control.dispatchEvent(new CustomEvent("change"));
      await flush();
    };
    const order = (element, status) =>
      Array.from(
        element.shadowRoot.querySelectorAll(
          `[data-column="${status}"] c-board-card`
        )
      ).map((node) => node.dataset.key);
    const cards3 = (w1Status) =>
      board([
        item({
          id: "w1",
          recordNumber: "WI-0001",
          status: w1Status,
          priority: "Third",
          priorityRank: 3
        }),
        item({
          id: "w2",
          recordNumber: "WI-0002",
          status: "In Progress",
          priority: "First",
          priorityRank: 1,
          dueDate: "2026-12-01"
        }),
        item({
          id: "w3",
          recordNumber: "WI-0003",
          status: "In Progress",
          dueDate: "2026-10-01"
        })
      ]);

    it("opens on Due date, sorts by Priority, and keeps it across a live refresh", async () => {
      const element = mount();
      getBoardData.emit(cards3("In Progress"));
      await flush();
      expect(order(element, "In Progress")).toStrictEqual(["w3", "w2", "w1"]);

      await sortBy(element, "priority");
      expect(order(element, "In Progress")).toStrictEqual(["w2", "w1", "w3"]);

      // What a Change Data Capture refresh does: the wire emits again.
      getBoardData.emit(cards3("In Progress"));
      await flush();
      expect(order(element, "In Progress")).toStrictEqual(["w2", "w1", "w3"]);
    });

    it("lands a card moved with Move to in its sorted place, with focus on it", async () => {
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "In Progress",
        syncStatus: "Pending",
        pushQueued: true,
        message: "Saved."
      });
      refreshApex.mockImplementationOnce(() => {
        getBoardData.emit(cards3("In Progress"));
        return Promise.resolve();
      });
      const element = mount();
      getBoardData.emit(cards3("To Do"));
      await flush();
      await sortBy(element, "priority");
      await openCard(element, "w1");

      inCard(element, "w1", '[data-move="In Progress"]').click();
      await flush();
      await flush();
      await flush();

      // Third priority: after First, before none.
      expect(order(element, "In Progress")).toStrictEqual(["w2", "w1", "w3"]);
      const moved = cardFor(element, "w1");
      expect(moved.shadowRoot.activeElement).toBe(
        moved.shadowRoot.querySelector("[data-disclosure]")
      );
    });

    it("lands a dropped card in its sorted place", async () => {
      window.matchMedia = jest.fn((query) => ({
        matches: query === "(pointer: fine)",
        addEventListener() {},
        removeEventListener() {}
      }));
      changeStatus.mockResolvedValue({
        workItemId: "w1",
        status: "In Progress",
        syncStatus: "Pending",
        pushQueued: true,
        message: "Saved."
      });
      refreshApex.mockImplementationOnce(() => {
        getBoardData.emit(cards3("In Progress"));
        return Promise.resolve();
      });
      const element = mount();
      getBoardData.emit(cards3("To Do"));
      await flush();
      await sortBy(element, "priority");

      const drag = (type) => {
        const event = new CustomEvent(type, {
          bubbles: true,
          cancelable: true
        });
        Object.defineProperty(event, "dataTransfer", {
          value: {
            setData() {},
            setDragImage() {},
            effectAllowed: "",
            dropEffect: ""
          }
        });
        return event;
      };
      const target = element.shadowRoot.querySelector(
        '[data-column="In Progress"]'
      );
      inCard(element, "w1", "[data-drag-surface]").dispatchEvent(
        drag("dragstart")
      );
      await flush();
      target.dispatchEvent(drag("dragover"));
      target.dispatchEvent(drag("drop"));
      await flush();
      await flush();
      await flush();

      expect(order(element, "In Progress")).toStrictEqual(["w2", "w1", "w3"]);
      delete window.matchMedia;
    });
  });

  // Build 10 step 3. Featuring an epic on the public board, from the open epic card.
  describe("the featured epic (build 10)", () => {
    const epic = (overrides) =>
      Object.assign(
        {
          id: "e1",
          recordNumber: "WI-0000",
          title: "Integration app",
          status: "In Progress",
          totalChildren: 1,
          completedChildren: 0,
          sourceLabel: "Jira",
          accentToken: "accent-1",
          isFeatured: false
        },
        overrides
      );
    const data = ({ canFeatureEpic = true, featured = null } = {}) => {
      const d = board([
        item({ id: "e1", recordNumber: "WI-0000", type: "Epic" }),
        item({ id: "e2", recordNumber: "WI-0001", type: "Epic" }),
        item({ id: "s1", recordNumber: "WI-0003", parentId: "e1" }),
        item({
          id: "a1",
          recordNumber: "WI-0015",
          title: "Deep Work",
          externalKey: null,
          type: "Book",
          sourceLabel: "Asana",
          accentToken: "accent-2",
          condensesIntoEpic: false,
          supportsStartDate: false
        })
      ]);
      d.canFeatureEpic = canFeatureEpic;
      d.featuredEpicId = featured;
      d.epics = [
        epic({ isFeatured: featured === "e1" }),
        epic({
          id: "e2",
          recordNumber: "WI-0001",
          title: "Shipped work",
          status: "Done",
          totalChildren: 0,
          isFeatured: featured === "e2"
        })
      ];
      return d;
    };
    const epicCard = (element, id) =>
      element.shadowRoot.querySelector(
        `c-board-epic-card[data-key="epic-${id}"]`
      );
    const inEpic = (element, id, selector) =>
      epicCard(element, id).shadowRoot.querySelector(selector);
    async function showEpics(element, payload) {
      getBoardData.emit(payload);
      await flush();
      await choose(element, "view", "epics");
    }
    async function openEpic(element, id) {
      inEpic(element, id, "[data-disclosure]").click();
      await flush();
    }
    // The Apex call, the feedback, the refresh and the render each take a turn.
    const settle = () =>
      flush().then(flush).then(flush).then(flush).then(flush);

    it("shows the indicator on the epic the payload marks, and moves it when the payload does", async () => {
      const element = mount();
      await showEpics(element, data({ featured: "e1" }));
      expect(inEpic(element, "e1", "[data-featured]").textContent).toBe(
        "★Featured on the public board"
      );
      expect(inEpic(element, "e2", "[data-featured]")).toBeNull();

      getBoardData.emit(data({ featured: "e2" }));
      await flush();
      expect(inEpic(element, "e1", "[data-featured]")).toBeNull();
      expect(inEpic(element, "e2", "[data-featured]")).not.toBeNull();

      getBoardData.emit(data());
      await flush();
      expect(
        element.shadowRoot.querySelectorAll("c-board-epic-card")
      ).toHaveLength(2);
      expect(inEpic(element, "e1", "[data-featured]")).toBeNull();
      expect(inEpic(element, "e2", "[data-featured]")).toBeNull();
    });

    it("offers the button on epic cards only, and only with the permission", async () => {
      const element = mount();
      await showEpics(element, data({ featured: "e1" }));
      await openEpic(element, "e1");
      expect(
        inEpic(element, "e1", "[data-action='feature']").textContent.trim()
      ).toBe("Remove from public board");
      await openEpic(element, "e2");
      expect(
        inEpic(element, "e2", "[data-action='feature']").textContent.trim()
      ).toBe("Feature on public board");

      // The flat card passing through the Epics view, open: no such button.
      await openCard(element, "a1");
      const flat = cardFor(element, "a1");
      expect(
        flat.shadowRoot
          .querySelector("[data-disclosure]")
          .getAttribute("aria-expanded")
      ).toBe("true");
      expect(
        flat.shadowRoot.querySelector("[data-action='feature']")
      ).toBeNull();

      // And in the Tasks view, where every card is a task card.
      await choose(element, "view", "tasks");
      expect(
        element.shadowRoot.querySelectorAll("c-board-epic-card")
      ).toHaveLength(0);
      expect(
        cards(element).some((c) =>
          c.shadowRoot.querySelector("[data-action='feature']")
        )
      ).toBe(false);
    });

    it("offers no button without the permission", async () => {
      const element = mount();
      await showEpics(element, data({ canFeatureEpic: false, featured: "e1" }));
      await openEpic(element, "e1");
      expect(inEpic(element, "e1", "[data-action='feature']")).toBeNull();
      // The indicator is for everyone who can see the board; only the button needs the permission.
      expect(inEpic(element, "e1", "[data-featured]")).not.toBeNull();
    });

    it("features an epic, says so, and refreshes itself", async () => {
      featureEpic.mockResolvedValue({
        saved: true,
        refused: false,
        message: "WI-0001 is featured on the public board, in place of WI-0000."
      });
      const element = mount();
      await showEpics(element, data({ featured: "e1" }));
      await openEpic(element, "e2");

      inEpic(element, "e2", "[data-action='feature']").click();
      await settle();

      expect(featureEpic).toHaveBeenCalledWith({ epicId: "e2" });
      expect(unfeatureEpic).not.toHaveBeenCalled();
      expect(refreshApex).toHaveBeenCalledTimes(1);
      expect(inEpic(element, "e2", "[data-feedback]").textContent.trim()).toBe(
        "WI-0001 is featured on the public board, in place of WI-0000."
      );
      expect(inEpic(element, "e2", "[data-feedback]").className).not.toContain(
        "feedback-error"
      );

      // The refresh brings the replaced payload: the indicator moves, the button flips.
      getBoardData.emit(data({ featured: "e2" }));
      await flush();
      expect(inEpic(element, "e1", "[data-featured]")).toBeNull();
      expect(inEpic(element, "e2", "[data-featured]")).not.toBeNull();
      expect(
        inEpic(element, "e2", "[data-action='feature']").textContent.trim()
      ).toBe("Remove from public board");
    });

    it("removes the featured epic with the epic it was pressed on", async () => {
      unfeatureEpic.mockResolvedValue({
        saved: true,
        refused: false,
        message: "WI-0000 is no longer featured on the public board."
      });
      const element = mount();
      await showEpics(element, data({ featured: "e1" }));
      await openEpic(element, "e1");

      inEpic(element, "e1", "[data-action='feature']").click();
      await settle();

      expect(unfeatureEpic).toHaveBeenCalledWith({ epicId: "e1" });
      expect(featureEpic).not.toHaveBeenCalled();
      expect(refreshApex).toHaveBeenCalledTimes(1);

      getBoardData.emit(data());
      await flush();
      expect(inEpic(element, "e1", "[data-featured]")).toBeNull();
      expect(
        inEpic(element, "e1", "[data-action='feature']").textContent.trim()
      ).toBe("Feature on public board");
    });

    it("shows a refusal as an error, and a failed call too", async () => {
      featureEpic.mockResolvedValueOnce({
        saved: false,
        refused: true,
        message: "WI-0001 is not public, so the public board cannot show it."
      });
      const element = mount();
      await showEpics(element, data());
      await openEpic(element, "e2");
      inEpic(element, "e2", "[data-action='feature']").click();
      await settle();
      expect(inEpic(element, "e2", "[data-feedback]").className).toContain(
        "feedback-error"
      );
      expect(inEpic(element, "e2", "[data-feedback]").textContent.trim()).toBe(
        "WI-0001 is not public, so the public board cannot show it."
      );

      featureEpic.mockRejectedValueOnce({
        body: { message: "Only someone with the permission can change it." }
      });
      inEpic(element, "e2", "[data-action='feature']").click();
      await settle();
      expect(inEpic(element, "e2", "[data-feedback]").textContent.trim()).toBe(
        "Only someone with the permission can change it."
      );
      expect(inEpic(element, "e2", "[data-feedback]").className).toContain(
        "feedback-error"
      );
    });

    it("is accessible with the featured epic open and a message showing", async () => {
      featureEpic.mockResolvedValue({
        saved: true,
        refused: false,
        message: "WI-0000 is featured on the public board."
      });
      const element = mount();
      const payload = data({ featured: "e1" });
      payload.canOpenRecord = true;
      await showEpics(element, payload);
      await openEpic(element, "e1");
      await settle();
      await expect(element).toBeAccessible();
    });
  });
});
