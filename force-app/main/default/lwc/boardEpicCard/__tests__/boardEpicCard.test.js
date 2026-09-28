import { createElement } from "lwc";
import BoardEpicCard from "c/boardEpicCard";
import { epicModel, FEATURED_LABEL_INTERNAL } from "c/boardModel";

function mount(overrides, props, modelOptions) {
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
    { key: "epic-0", ...(modelOptions || {}) }
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

  // ---------- the featured epic (build 10 step 3) ----------

  describe("the featured epic", () => {
    const internal = { featuredLabel: FEATURED_LABEL_INTERNAL };
    const grants = (extra) => ({
      expandedKey: "epic-0",
      abilities: Object.assign({ featureEpic: true }, extra)
    });

    it("says it is featured in words, and the header is described by them", () => {
      const element = mount({ isFeatured: true }, {}, internal);
      const indicator = $(element, "[data-featured]");
      expect(indicator.textContent).toBe("★Featured on the public board");
      expect(indicator.querySelector(".star").getAttribute("aria-hidden")).toBe(
        "true"
      );
      expect(
        $(element, "[data-disclosure]").getAttribute("aria-describedby")
      ).toBe(indicator.id);
    });

    it("shows no indicator, and describes the header by nothing, when not featured", () => {
      const element = mount({ isFeatured: false }, {}, internal);
      expect($(element, "[data-featured]")).toBeNull();
      expect(
        $(element, "[data-disclosure]").hasAttribute("aria-describedby")
      ).toBe(false);
    });

    it("offers Feature on a card that is not featured, and Remove on the one that is", () => {
      const plain = mount({ isFeatured: false }, grants(), internal);
      expect($(plain, "[data-action='feature']").textContent.trim()).toBe(
        "Feature on public board"
      );
      const featured = mount({ isFeatured: true }, grants(), internal);
      expect($(featured, "[data-action='feature']").textContent.trim()).toBe(
        "Remove from public board"
      );
    });

    it("asks the board, and says which way", () => {
      const handler = jest.fn();
      const plain = mount({ isFeatured: false }, grants(), internal);
      plain.addEventListener("feature", handler);
      $(plain, "[data-action='feature']").click();
      const featured = mount({ isFeatured: true }, grants(), internal);
      featured.addEventListener("feature", handler);
      $(featured, "[data-action='feature']").click();

      expect(handler.mock.calls.map((call) => call[0].detail)).toStrictEqual([
        { key: "epic-0", feature: true },
        { key: "epic-0", feature: false }
      ]);
    });

    it("has no button without the ability: the public board, or a user without the permission", () => {
      expect(
        $(
          mount({ isFeatured: true }, { expandedKey: "epic-0" }),
          "[data-action='feature']"
        )
      ).toBeNull();
      expect(
        $(mount({}, grants({ featureEpic: false })), "[data-action='feature']")
      ).toBeNull();
    });

    it("puts the button before the record link, in the keyboard's order", () => {
      const element = mount(
        { id: "a0E1", recordNumber: "WI-0000" },
        {
          ...grants({ openRecord: true }),
          recordLink: { key: "epic-0", url: "/r/a0E1" }
        },
        internal
      );
      const controls = Array.from(
        element.shadowRoot.querySelectorAll("button, a[href]")
      ).map(
        (node) =>
          (node.dataset &&
            (node.dataset.action ||
              ("recordLink" in node.dataset ? "record" : null))) ||
          ("disclosure" in node.dataset ? "disclosure" : "unknown")
      );
      expect(controls).toStrictEqual(["disclosure", "feature", "record"]);
    });

    it("waits while the board works, then says what happened", async () => {
      const handler = jest.fn();
      const element = mount({}, grants(), internal);
      element.addEventListener("feature", handler);

      element.feedback = { key: "epic-0", busy: true };
      await Promise.resolve();
      const button = $(element, "[data-action='feature']");
      expect(button.getAttribute("aria-disabled")).toBe("true");
      button.click();
      expect(handler).not.toHaveBeenCalled();
      expect($(element, "[data-feedback]").textContent.trim()).toBe("Saving…");
      expect($(element, "[data-feedback]").getAttribute("role")).toBe("status");

      element.feedback = {
        key: "epic-0",
        tone: "error",
        message: "WI-0002 is not public, so the public board cannot show it."
      };
      await Promise.resolve();
      expect($(element, "[data-feedback]").className).toContain(
        "feedback-error"
      );
      expect(button.getAttribute("aria-disabled")).toBe("false");

      element.feedback = { key: "epic-9", tone: "ok", message: "Another card" };
      await Promise.resolve();
      expect($(element, "[data-feedback]").textContent.trim()).toBe("");
    });

    it("is accessible featured, closed and open with the button, link and a message", async () => {
      await expect(mount({ isFeatured: true }, {}, internal)).toBeAccessible();
      const open = mount(
        { isFeatured: true, recordNumber: "WI-0000" },
        {
          ...grants({ openRecord: true }),
          recordLink: { key: "epic-0", url: "/r/a0E1" },
          feedback: {
            key: "epic-0",
            tone: "ok",
            message: "WI-0000 is featured on the public board."
          }
        },
        internal
      );
      await expect(open).toBeAccessible();
    });
  });
});
