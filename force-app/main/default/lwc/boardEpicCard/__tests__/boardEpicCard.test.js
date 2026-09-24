import { createElement } from "lwc";
import BoardEpicCard from "c/boardEpicCard";
import { epicModel } from "c/boardModel";

function mount(overrides, props) {
  const element = createElement("c-board-epic-card", { is: BoardEpicCard });
  element.epic = epicModel(
    Object.assign(
      {
        title: "Guest board",
        status: "In Progress",
        totalChildren: 4,
        completedChildren: 3,
        sourceLabel: "Source A",
        accentToken: "accent-1"
      },
      overrides
    ),
    { key: "epic-0" }
  );
  Object.assign(element, props || {});
  document.body.appendChild(element);
  return element;
}

const $ = (element, selector) => element.shadowRoot.querySelector(selector);

describe("c-board-epic-card", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("shows progress in words, with a decorative bar beside it", () => {
    const element = mount();
    expect($(element, ".count").textContent).toBe("3 of 4 done");
    expect($(element, ".bar").style.width).toBe("75%");
    expect($(element, ".track").getAttribute("aria-hidden")).toBe("true");
  });

  it("draws no bar for an epic with nothing under it", () => {
    const element = mount({ totalChildren: 0, completedChildren: 0 });
    expect($(element, ".count").textContent).toBe("No child items yet");
    expect($(element, ".track")).toBeNull();
  });

  it("names its source in its accent", () => {
    const element = mount();
    expect($(element, "[data-source]").textContent).toBe("Source A");
    expect($(element, "article").getAttribute("data-accent")).toBe("accent-1");
  });

  it("clamps its title like every other card", () => {
    // The class carries the two-line clamp; the build 06 epic card had none, and a real
    // summary ran to four lines in a column.
    expect($(mount(), "h3 .heading")).not.toBeNull();
  });

  it("shows a record number only when the payload has one", () => {
    expect($(mount(), ".id")).toBeNull();
    expect($(mount({ recordNumber: "WI-0000" }), ".id").textContent).toBe(
      "WI-0000"
    );
  });

  it("has one control, its disclosure, unless the board grants the link", () => {
    const element = mount({}, { expandedKey: "epic-0" });
    const controls = Array.from(
      element.shadowRoot.querySelectorAll("button, input, a[href], [tabindex]")
    );
    expect(controls.map((node) => node.dataset.disclosure)).toStrictEqual([""]);
    expect($(element, "article").getAttribute("role")).toBeNull();
  });

  it("opens in place to show the whole title", () => {
    const closed = mount();
    const header = $(closed, "h3 button[data-disclosure]");
    expect(header.getAttribute("aria-expanded")).toBe("false");
    expect(header.getAttribute("aria-controls")).toBe(
      $(closed, "[data-details]").id
    );
    const handler = jest.fn();
    closed.addEventListener("toggle", handler);
    header.click();
    expect(handler.mock.calls[0][0].detail).toEqual({ key: "epic-0" });

    const open = mount({}, { expandedKey: "epic-0" });
    expect($(open, "[data-disclosure]").getAttribute("aria-expanded")).toBe(
      "true"
    );
    expect($(open, ".heading").className).toContain("is-open");
  });

  it("links to the epic's record on the internal board only", () => {
    const element = mount(
      { id: "a0E1", recordNumber: "WI-0000" },
      {
        expandedKey: "epic-0",
        abilities: { openRecord: true },
        recordLink: { key: "epic-0", url: "/r/a0E1" }
      }
    );
    const link = $(element, "[data-record-link]");
    expect(link.getAttribute("href")).toBe("/r/a0E1");
    expect(link.getAttribute("aria-label")).toBe("Open record WI-0000");
  });

  it("is accessible, closed and open", async () => {
    await expect(mount({ title: null, totalChildren: 0 })).toBeAccessible();
    await expect(
      mount(
        { recordNumber: "WI-0000" },
        {
          expandedKey: "epic-0",
          abilities: { openRecord: true },
          recordLink: { key: "epic-0", url: "/r/a0E1" }
        }
      )
    ).toBeAccessible();
  });
});
