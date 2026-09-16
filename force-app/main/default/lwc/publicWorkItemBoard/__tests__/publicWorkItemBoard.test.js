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
      lastSyncedAt: "2026-09-13T05:20:07.000Z"
    },
    overrides
  );
}

function board(items) {
  return {
    items,
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

  it("offers no control that could change anything", async () => {
    const element = mount();
    getPublicBoardData.emit(board([card()]));
    await flush();

    expect(element.shadowRoot.querySelectorAll("button")).toHaveLength(0);
    const article = cards(element)[0].shadowRoot.querySelector("article");
    expect(article.getAttribute("role")).toBeNull();
    expect(article.getAttribute("tabindex")).toBeNull();
  });
});
