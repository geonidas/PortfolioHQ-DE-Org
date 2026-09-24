import { createElement } from "lwc";
import BoardCard from "c/boardCard";
import { cardModel } from "c/boardModel";

const NOW = new Date(2026, 8, 24, 12, 0, 0);

/** A card payload as either controller sends it, turned into the model the boards hand over. */
function model(overrides, options) {
  return cardModel(
    Object.assign(
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
        createdAt: "2026-09-12T12:00:00.000Z",
        startDate: "2026-09-24",
        dueDate: "2026-10-01"
      },
      overrides
    ),
    Object.assign({ now: NOW }, options)
  );
}

function mount(card, props) {
  const element = createElement("c-board-card", { is: BoardCard });
  element.card = card;
  Object.assign(element, props || {});
  document.body.appendChild(element);
  return element;
}

const $ = (element, selector) => element.shadowRoot.querySelector(selector);
const visibleText = (node) =>
  node.querySelector("[aria-hidden='true']").textContent;

describe("c-board-card", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("leads with the title", () => {
    const element = mount(model());
    expect($(element, ".heading").textContent).toBe(
      "Render work items on the board"
    );
    expect($(element, "h3")).not.toBeNull();
  });

  it("names its source in the accent it paints", () => {
    const element = mount(model());
    expect($(element, "[data-source]").textContent).toBe("Source A");
    expect($(element, "article").getAttribute("data-accent")).toBe("accent-1");
  });

  it("renders an unknown or missing token as neutral, not as a source", () => {
    const element = mount(model({ accentToken: null, sourceLabel: null }));
    expect($(element, "article").getAttribute("data-accent")).toBe("none");
    expect($(element, "[data-source]")).toBeNull();
  });

  it("shows both identifiers when the source has a key of its own", () => {
    const element = mount(model());
    expect(
      Array.from(element.shadowRoot.querySelectorAll(".id")).map(
        (id) => id.lastChild.textContent
      )
    ).toEqual(["WI-0003", "DOPP-17"]);
    expect(element.shadowRoot.querySelectorAll(".sep")).toHaveLength(3);
  });

  it("shows the record number once when the source has no key", () => {
    const element = mount(model({ externalKey: null }));
    const ids = element.shadowRoot.querySelectorAll(".id");
    expect(ids).toHaveLength(1);
    expect(ids[0].textContent).toBe("WI-0003");
  });

  it("hides the separators from screen readers and says the line in words", () => {
    const element = mount(model());
    const meta = $(element, "[data-meta]");
    expect(meta.querySelector(".assistive").textContent).toBe(
      "Source A, WI-0003, DOPP-17, Story"
    );
    // Everything drawn for the eye, dots included, is hidden from the accessibility tree.
    expect(visibleText(meta)).toContain("·");
    meta
      .querySelectorAll(".sep")
      .forEach((sep) =>
        expect(sep.closest("[aria-hidden='true']")).not.toBeNull()
      );
  });

  it("shows created, start and due dates", () => {
    const element = mount(model());
    const dates = $(element, "[data-dates]");
    expect(dates.querySelector(".assistive").textContent).toBe(
      "Created 12 Sep, Start 24 Sep, Due 1 Oct"
    );
    expect($(element, "[data-date='due']").textContent).toContain("Due 1 Oct");
  });

  it("drops the date line when there are no dates", () => {
    const element = mount(
      model({ createdAt: null, startDate: null, dueDate: null })
    );
    expect($(element, "[data-dates]")).toBeNull();
  });

  it("says Overdue only when the board asked for it", () => {
    const late = { dueDate: "2026-09-20" };
    expect($(mount(model(late)), "[data-date='overdue']")).toBeNull();
    const flagged = mount(model(late, { showOverdue: true }));
    expect($(flagged, "[data-date='overdue']").textContent).toContain(
      "Overdue"
    );
  });

  it("omits the type chip when the type is unknown", () => {
    expect($(mount(model({ type: null })), "[data-type]")).toBeNull();
  });

  it("flags Pending and Failed, and nothing else", () => {
    expect(
      $(mount(model({ syncStatus: "Pending" })), "[data-sync]").className
    ).toBe("chip sync sync-pending");
    expect(
      $(mount(model({ syncStatus: "Failed" })), "[data-sync]").className
    ).toBe("chip sync sync-failed");
    expect($(mount(model({ syncStatus: "Synced" })), "[data-sync]")).toBeNull();
    expect($(mount(model({ syncStatus: null })), "[data-sync]")).toBeNull();
  });

  it("has no description line, and no placeholder for one", () => {
    const element = mount(model({ description: "Should not show" }));
    expect(element.shadowRoot.textContent).not.toContain("Should not show");
    expect(element.shadowRoot.textContent).not.toContain("No description");
  });

  it("offers nothing to act on unless the board grants it", () => {
    const element = mount(model());
    expect(element.shadowRoot.querySelector("button")).toBeNull();
    expect($(element, "article").getAttribute("role")).toBeNull();
    expect($(element, "article").getAttribute("tabindex")).toBeNull();
  });

  it("raises select from a real button in its heading when selectable", () => {
    const element = mount(model(), { selectable: true });
    const handler = jest.fn();
    element.addEventListener("select", handler);

    const button = $(element, "h3 button[data-select]");
    expect(button.type).toBe("button");
    button.click();

    expect(handler).toHaveBeenCalledTimes(1);
    expect(handler.mock.calls[0][0].detail).toEqual({ key: "WI-0003" });
    // The card itself is no longer the control: no role on the article, nothing flattened.
    expect($(element, "article").getAttribute("role")).toBeNull();
  });

  describe("accessibility", () => {
    // The step 1 pin was aria-allowed-role, for the old <article role="button">. The card now
    // puts a real button in its heading instead, so there is nothing left to pin.
    it("is accessible when inert", async () => {
      await expect(mount(model())).toBeAccessible();
    });

    it("is accessible when selectable, flagged, overdue and untitled", async () => {
      const element = mount(
        model(
          { title: null, syncStatus: "Failed", dueDate: "2026-09-01" },
          {
            showOverdue: true
          }
        ),
        { selectable: true }
      );
      await expect(element).toBeAccessible();
    });
  });
});
