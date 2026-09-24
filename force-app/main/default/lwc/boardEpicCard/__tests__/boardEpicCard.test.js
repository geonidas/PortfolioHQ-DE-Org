import { createElement } from "lwc";
import BoardEpicCard from "c/boardEpicCard";
import { epicModel } from "c/boardModel";

function mount(overrides) {
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

  it("is inert", () => {
    const element = mount();
    expect(element.shadowRoot.querySelector("button")).toBeNull();
    expect($(element, "article").getAttribute("role")).toBeNull();
    expect($(element, "article").getAttribute("tabindex")).toBeNull();
  });

  it("is accessible", async () => {
    await expect(mount({ title: null, totalChildren: 0 })).toBeAccessible();
  });
});
