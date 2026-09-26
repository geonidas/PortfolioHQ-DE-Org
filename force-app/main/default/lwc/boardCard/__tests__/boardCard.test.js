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

  it("has one control, its disclosure, unless the board grants more", () => {
    const element = mount(model(), { expandedKey: "WI-0003" });
    const controls = Array.from(
      element.shadowRoot.querySelectorAll(
        "button, input, select, textarea, a[href], [tabindex]"
      )
    );
    // Open, and still nothing to act with: no Move to, no editor, no link.
    expect(controls.map((node) => node.dataset.disclosure)).toStrictEqual([""]);
    expect($(element, "article").getAttribute("role")).toBeNull();
  });

  describe("disclosure", () => {
    it("is a button in the heading that says whether it is open", () => {
      const closed = mount(model());
      const header = $(closed, "h3 button[data-disclosure]");
      expect(header.type).toBe("button");
      expect(header.getAttribute("aria-expanded")).toBe("false");
      // It names what it controls, and that region exists open or closed.
      const region = $(closed, "[data-details]");
      expect(header.getAttribute("aria-controls")).toBe(region.id);
      expect(region.hidden).toBe(true);

      const open = mount(model(), { expandedKey: "WI-0003" });
      expect($(open, "[data-disclosure]").getAttribute("aria-expanded")).toBe(
        "true"
      );
      expect($(open, "[data-details]").hidden).toBe(false);
    });

    it("is named by the title and the sync state", () => {
      const element = mount(model({ syncStatus: "Pending" }));
      expect($(element, "[data-disclosure]").getAttribute("aria-label")).toBe(
        "Render work items on the board, Pending"
      );
    });

    it("asks the board to open it, and leaves the deciding to the board", () => {
      const element = mount(model());
      const handler = jest.fn();
      element.addEventListener("toggle", handler);

      $(element, "[data-disclosure]").click();

      expect(handler.mock.calls[0][0].detail).toEqual({ key: "WI-0003" });
      // Still closed: one card open at a time is the board's rule, not the card's.
      expect(
        $(element, "[data-disclosure]").getAttribute("aria-expanded")
      ).toBe("false");
    });

    it("closes on Escape and puts focus back on its header", async () => {
      const element = mount(model(), {
        expandedKey: "WI-0003",
        abilities: { edit: true, moveTo: [] }
      });
      const handler = jest.fn();
      element.addEventListener("toggle", handler);
      const title = $(element, "[data-field='title']");
      title.focus();

      title.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true })
      );

      expect(handler).toHaveBeenCalledTimes(1);
      expect(element.shadowRoot.activeElement).toBe(
        $(element, "[data-disclosure]")
      );
    });

    it("shows the whole title, the dates in full, the parent and the project when open", () => {
      const card = Object.assign(model({ projectLabel: "PHQ" }), {
        parentLine: "WI-0002"
      });
      const element = mount(card, { expandedKey: "WI-0003" });

      expect($(element, ".heading").className).toContain("is-open");
      expect($(element, "[data-dates] .assistive").textContent).toBe(
        "Created 12 Sep 2026, Start 24 Sep 2026, Due 1 Oct 2026"
      );
      expect($(element, "[data-parent]").textContent).toBe("WI-0002");
      expect($(element, "[data-project]").textContent).toBe("PHQ");
    });

    it("shows a description only when open, and only when there is one", () => {
      const withText = model({ description: "Cards grouped by status." });
      expect($(mount(withText), "[data-description]")).toBeNull();
      expect(
        $(mount(withText, { expandedKey: "WI-0003" }), "[data-description]")
          .textContent
      ).toBe("Cards grouped by status.");
      const without = mount(model(), { expandedKey: "WI-0003" });
      expect($(without, "[data-description]")).toBeNull();
      expect(without.shadowRoot.textContent).not.toContain("No description");
    });
  });

  describe("abilities, internal board only", () => {
    const ABILITIES = {
      moveTo: ["To Do", "In Progress", "Done"],
      edit: true,
      openRecord: true,
      titleMax: 20
    };
    const openCard = (overrides, props) =>
      mount(
        Object.assign(
          model(Object.assign({ supportsStartDate: true }, overrides)),
          { key: "a0B1", syncNote: "In step with Source A." }
        ),
        Object.assign({ expandedKey: "a0B1", abilities: ABILITIES }, props)
      );
    const setInput = (element, field, value) => {
      const input = $(element, `[data-field='${field}']`);
      input.value = value;
      input.dispatchEvent(
        new CustomEvent(field === "title" ? "input" : "change")
      );
    };
    const submit = async (element) => {
      $(element, "form").dispatchEvent(
        new CustomEvent("submit", { cancelable: true })
      );
      await Promise.resolve();
    };

    it("offers Move to for every column but its own", () => {
      const element = openCard();
      const handler = jest.fn();
      element.addEventListener("move", handler);
      const moves = Array.from(
        element.shadowRoot.querySelectorAll("[data-move]")
      );

      expect(moves.map((b) => b.dataset.move)).toStrictEqual(["To Do", "Done"]);
      moves[1].click();
      expect(handler.mock.calls[0][0].detail).toEqual({
        key: "a0B1",
        status: "Done"
      });
    });

    it("explains its sync state in the source's words", () => {
      expect($(openCard(), "[data-sync-note]").textContent).toBe(
        "In step with Source A."
      );
    });

    it("edits title, start and due, and sends them as typed", async () => {
      const element = openCard();
      const handler = jest.fn();
      element.addEventListener("save", handler);

      setInput(element, "title", "A new title");
      setInput(element, "startDate", "2026-09-25");
      setInput(element, "dueDate", "2026-10-03");
      await submit(element);

      expect(handler.mock.calls[0][0].detail).toEqual({
        key: "a0B1",
        title: "A new title",
        startDate: "2026-09-25",
        dueDate: "2026-10-03"
      });
    });

    it("has no start date input for a source without start dates, and says why", () => {
      const element = openCard({ supportsStartDate: false });
      expect($(element, "[data-field='startDate']")).toBeNull();
      expect($(element, "[data-no-start]").textContent).toBe(
        "Source A items have no start date."
      );
      expect($(element, "[data-field='dueDate']")).not.toBeNull();
    });

    it("refuses an empty title, an over-long one and a start after due, beside each field", async () => {
      const element = openCard();
      const handler = jest.fn();
      element.addEventListener("save", handler);

      setInput(element, "title", "   ");
      setInput(element, "startDate", "2026-10-05");
      setInput(element, "dueDate", "2026-10-01");
      await submit(element);

      expect(handler).not.toHaveBeenCalled();
      expect($(element, "[data-error='title']").textContent.trim()).toBe(
        "A title is required. Type one before saving."
      );
      expect($(element, "[data-error='startDate']").textContent.trim()).toBe(
        "The start date (2026-10-05) is after the due date (2026-10-01). Move one of them."
      );
      const title = $(element, "[data-field='title']");
      expect(title.getAttribute("aria-invalid")).toBe("true");
      // Focus goes to the first field that needs fixing.
      expect(element.shadowRoot.activeElement).toBe(title);

      setInput(element, "title", "x".repeat(25));
      await submit(element);
      expect($(element, "[data-error='title']").textContent.trim()).toBe(
        "The title is 25 characters; the limit is 20. Shorten it by 5."
      );
    });

    it("shows the server's field errors beside their fields until they are edited", async () => {
      const element = openCard();
      element.feedback = {
        key: "a0B1",
        tone: "error",
        message: "Nothing was saved. Fix the fields marked below.",
        fieldErrors: {
          startDate:
            "Source A does not support start dates. Clear the start date to save."
        }
      };
      await Promise.resolve();

      expect($(element, "[data-feedback]").textContent.trim()).toBe(
        "Nothing was saved. Fix the fields marked below."
      );
      expect($(element, "[data-error='startDate']").textContent.trim()).toBe(
        "Source A does not support start dates. Clear the start date to save."
      );

      setInput(element, "startDate", "");
      await Promise.resolve();
      expect($(element, "[data-error='startDate']").textContent.trim()).toBe(
        ""
      );
    });

    it("says it is saving, and will not send twice", async () => {
      const element = openCard();
      const handler = jest.fn();
      element.addEventListener("save", handler);
      element.feedback = { key: "a0B1", busy: true };
      await Promise.resolve();

      await submit(element);

      expect(handler).not.toHaveBeenCalled();
      expect($(element, "[data-feedback]").textContent.trim()).toBe("Saving…");
      expect(
        $(element, "[data-action='save']").getAttribute("aria-disabled")
      ).toBe("true");
    });

    it("keeps the draft until it is saved or cancelled", async () => {
      const element = openCard();
      setInput(element, "title", "Half typed");
      await Promise.resolve();
      expect($(element, "[data-field='title']").value).toBe("Half typed");

      $(element, "[data-action='cancel']").click();
      await Promise.resolve();
      expect($(element, "[data-field='title']").value).toBe(
        "Render work items on the board"
      );

      setInput(element, "title", "Saved title");
      element.feedback = {
        key: "a0B1",
        tone: "ok",
        saved: true,
        message: "Saved."
      };
      await Promise.resolve();
      // What is saved is what the card now shows, once the board's refresh arrives.
      expect($(element, "[data-field='title']").value).toBe(
        "Render work items on the board"
      );
    });

    it("links to the record only with the ability and a link for this card", async () => {
      expect($(openCard(), "[data-record-link]")).toBeNull();

      const element = openCard(
        {},
        { recordLink: { key: "a0B1", url: "/r/a0B1" } }
      );
      const link = $(element, "[data-record-link]");
      expect(link.getAttribute("href")).toBe("/r/a0B1");
      expect(link.getAttribute("aria-label")).toBe("Open record WI-0003");

      const handler = jest.fn();
      element.addEventListener("openrecord", handler);
      link.dispatchEvent(
        new MouseEvent("click", { button: 0, bubbles: true, cancelable: true })
      );
      expect(handler.mock.calls[0][0].detail).toEqual({ key: "a0B1" });

      // A link generated for another card is not this card's.
      const other = openCard({}, { recordLink: { key: "zzz", url: "/r/zzz" } });
      expect($(other, "[data-record-link]")).toBeNull();

      // Without the ability, a link handed over anyway is not shown.
      const denied = openCard(
        {},
        {
          abilities: { ...ABILITIES, openRecord: false },
          recordLink: { key: "a0B1", url: "/r/a0B1" }
        }
      );
      expect($(denied, "[data-record-link]")).toBeNull();
    });

    it("leaves a modified click on the link to the browser", () => {
      const element = openCard(
        {},
        { recordLink: { key: "a0B1", url: "/r/a0B1" } }
      );
      const handler = jest.fn();
      element.addEventListener("openrecord", handler);
      const link = $(element, "[data-record-link]");
      let leftToBrowser;
      // Runs after the card's own handler: records whether the card let the click through, then
      // stops jsdom, which cannot navigate, from trying.
      link.addEventListener("click", (event) => {
        leftToBrowser = !event.defaultPrevented;
        event.preventDefault();
      });

      link.dispatchEvent(
        new MouseEvent("click", {
          button: 0,
          metaKey: true,
          bubbles: true,
          cancelable: true
        })
      );

      expect(handler).not.toHaveBeenCalled();
      expect(leftToBrowser).toBe(true);
    });
  });

  // Build 08 step 8.
  describe("drag and retry, internal board only", () => {
    const DRAG = { moveTo: ["To Do", "Done"], edit: true, drag: true };
    /** jsdom has no DataTransfer; this records what the card puts on one. */
    function dragEvent(type) {
      const transfer = {
        effectAllowed: "",
        dropEffect: "",
        data: {},
        setData(kind, value) {
          this.data[kind] = value;
        },
        setDragImage: jest.fn()
      };
      const event = new CustomEvent(type, { bubbles: true, cancelable: true });
      Object.defineProperty(event, "dataTransfer", { value: transfer });
      Object.defineProperty(event, "clientX", { value: 40 });
      Object.defineProperty(event, "clientY", { value: 20 });
      return event;
    }
    const surface = (element) => $(element, "[data-drag-surface]");

    it("drags by its left edge and its detail lines, only when allowed and closed", () => {
      const draggables = (element) =>
        Array.from(
          element.shadowRoot.querySelectorAll("[draggable='true']")
        ).map((node) => {
          return node.hasAttribute("data-drag-edge") ? "edge" : "lines";
        });
      expect(draggables(mount(model()))).toStrictEqual([]);
      expect(
        draggables(mount(model(), { abilities: { ...DRAG, drag: false } }))
      ).toStrictEqual([]);
      expect(draggables(mount(model(), { abilities: DRAG }))).toStrictEqual([
        "edge",
        "lines"
      ]);
      // Open, it holds inputs; a drag never starts there.
      expect(
        draggables(mount(model(), { abilities: DRAG, expandedKey: "WI-0003" }))
      ).toStrictEqual([]);
    });

    it("never starts a drag from a button, an input or a link", () => {
      const element = mount(model(), { abilities: DRAG });
      const header = $(element, "[data-disclosure]");
      element.shadowRoot
        .querySelectorAll("[draggable='true']")
        .forEach((handle) => {
          expect(
            handle.querySelectorAll("button, input, select, textarea, a")
          ).toHaveLength(0);
          // The header - the disclosure - is outside everything that drags.
          expect(handle.contains(header)).toBe(false);
        });
      // The edge is for a pointer only: no focus, nothing to announce.
      const edge = $(element, "[data-drag-edge]");
      expect(edge.getAttribute("aria-hidden")).toBe("true");
      expect(edge.getAttribute("tabindex")).toBeNull();
    });

    it("starts the same drag from the edge as from the lines", () => {
      const element = mount(model(), { abilities: DRAG });
      const started = jest.fn();
      element.addEventListener("carddragstart", started);
      const event = dragEvent("dragstart");

      $(element, "[data-drag-edge]").dispatchEvent(event);

      expect(event.dataTransfer.data["application/x-work-item-key"]).toBe(
        "WI-0003"
      );
      expect(started.mock.calls[0][0].detail).toEqual({
        key: "WI-0003",
        status: "In Progress"
      });
    });

    it("carries its key, shows the whole card as the image, and tells the board", () => {
      const element = mount(model(), { abilities: DRAG });
      const started = jest.fn();
      element.addEventListener("carddragstart", started);
      const event = dragEvent("dragstart");

      surface(element).dispatchEvent(event);

      expect(event.dataTransfer.data["application/x-work-item-key"]).toBe(
        "WI-0003"
      );
      expect(event.dataTransfer.effectAllowed).toBe("move");
      expect(event.dataTransfer.setDragImage.mock.calls[0][0]).toBe(
        $(element, "article")
      );
      expect(started.mock.calls[0][0].detail).toEqual({
        key: "WI-0003",
        status: "In Progress"
      });
    });

    it("does not open or close when a drag ends", async () => {
      const element = mount(model(), { abilities: DRAG });
      const toggled = jest.fn();
      const ended = jest.fn();
      element.addEventListener("toggle", toggled);
      element.addEventListener("carddragend", ended);

      surface(element).dispatchEvent(dragEvent("dragstart"));
      await Promise.resolve();
      expect($(element, "article").className).toContain("is-dragging");
      surface(element).dispatchEvent(dragEvent("dragend"));
      surface(element).click();
      await Promise.resolve();

      expect(ended).toHaveBeenCalledTimes(1);
      expect(toggled).not.toHaveBeenCalled();
      expect($(element, "article").className).not.toContain("is-dragging");
      expect(
        $(element, "[data-disclosure]").getAttribute("aria-expanded")
      ).toBe("false");
    });

    it("refuses a drag it was not given", () => {
      const element = mount(model());
      const started = jest.fn();
      element.addEventListener("carddragstart", started);
      const event = dragEvent("dragstart");
      surface(element).dispatchEvent(event);
      expect(event.defaultPrevented).toBe(true);
      expect(started).not.toHaveBeenCalled();
    });

    it("offers Retry on a Failed card when the board grants it, and asks the board", () => {
      const failed = Object.assign(model({ syncStatus: "Failed" }), {
        key: "a0B1",
        syncNote: "Failed: it was refused."
      });
      const element = mount(failed, {
        expandedKey: "a0B1",
        abilities: { ...DRAG, retry: true }
      });
      const handler = jest.fn();
      element.addEventListener("retry", handler);

      $(element, "[data-action='retry']").click();

      expect(handler.mock.calls[0][0].detail).toEqual({ key: "a0B1" });
      // No Retry without the ability, or on a card that did not fail.
      expect(
        $(
          mount(failed, { expandedKey: "a0B1", abilities: DRAG }),
          "[data-action='retry']"
        )
      ).toBeNull();
      const pending = Object.assign(model({ syncStatus: "Pending" }), {
        key: "a0B2",
        syncNote: "Pending."
      });
      expect(
        $(
          mount(pending, {
            expandedKey: "a0B2",
            abilities: { ...DRAG, retry: true }
          }),
          "[data-action='retry']"
        )
      ).toBeNull();
    });

    it("dims while its move or retry is saving, and will not retry twice", async () => {
      const failed = Object.assign(model({ syncStatus: "Failed" }), {
        key: "a0B1",
        syncNote: "Failed."
      });
      const element = mount(failed, {
        expandedKey: "a0B1",
        abilities: { ...DRAG, retry: true },
        feedback: { key: "a0B1", busy: true }
      });
      const handler = jest.fn();
      element.addEventListener("retry", handler);
      $(element, "[data-action='retry']").click();
      expect(handler).not.toHaveBeenCalled();
      expect($(element, "article").className).toContain("is-busy");
    });

    it("is accessible draggable, and open with Retry", async () => {
      await expect(mount(model(), { abilities: DRAG })).toBeAccessible();
      await expect(
        mount(
          Object.assign(model({ syncStatus: "Failed" }), {
            key: "a0B1",
            syncNote: "Failed: it was refused."
          }),
          { expandedKey: "a0B1", abilities: { ...DRAG, retry: true } }
        )
      ).toBeAccessible();
    });
  });

  describe("accessibility", () => {
    // The step 1 pin was aria-allowed-role, for the old <article role="button">. The header is
    // a real button in the heading now, so there is nothing to pin.
    it("is accessible closed", async () => {
      await expect(mount(model())).toBeAccessible();
    });

    it("is accessible open with nothing to act with, as on the public board", async () => {
      const card = Object.assign(model({ projectLabel: "PHQ" }), {
        parentLine: "WI-0002"
      });
      await expect(mount(card, { expandedKey: "WI-0003" })).toBeAccessible();
    });

    it("is accessible open with every ability, errors showing and a link", async () => {
      const element = mount(
        Object.assign(
          model(
            {
              title: null,
              syncStatus: "Failed",
              dueDate: "2026-09-01",
              description: "Text"
            },
            { showOverdue: true }
          ),
          {
            key: "a0B1",
            syncNote: "Failed: it was refused.",
            parentLine: "WI-0002 A parent"
          }
        ),
        {
          expandedKey: "a0B1",
          abilities: {
            moveTo: ["To Do", "Done"],
            edit: true,
            openRecord: true,
            titleMax: 255
          },
          recordLink: { key: "a0B1", url: "/r/a0B1" },
          feedback: {
            key: "a0B1",
            tone: "error",
            message: "Nothing was saved.",
            fieldErrors: {
              title: "A title is required. Type one before saving."
            }
          }
        }
      );
      await expect(element).toBeAccessible();
    });

    it("is accessible open for a source without start dates", async () => {
      const element = mount(
        Object.assign(model({ supportsStartDate: false }), { key: "a0B1" }),
        { expandedKey: "a0B1", abilities: { edit: true, moveTo: [] } }
      );
      await expect(element).toBeAccessible();
    });
  });

  describe("priority (build 09)", () => {
    // Deliberately not real priority names: the card shows whatever the board sends.
    const OPTIONS = [
      { value: "P1", label: "First", rank: 1 },
      { value: "P2", label: "Second", rank: 2 },
      { value: "P3", label: "Third", rank: 3 }
    ];
    const ABILITIES = {
      moveTo: [],
      edit: true,
      titleMax: 255,
      priorityOptions: OPTIONS
    };
    const editable = (overrides, props) =>
      mount(
        Object.assign(
          model(
            Object.assign(
              {
                supportsStartDate: true,
                supportsPriority: true,
                priority: "Second",
                priorityRank: 2
              },
              overrides
            )
          ),
          { key: "a0B1" }
        ),
        Object.assign({ expandedKey: "a0B1", abilities: ABILITIES }, props)
      );
    const select = (element) => $(element, "[data-field='priority']");
    const choose = (element, value) => {
      select(element).value = value;
      select(element).dispatchEvent(new CustomEvent("change"));
    };
    const submit = async (element) => {
      $(element, "form").dispatchEvent(
        new CustomEvent("submit", { cancelable: true })
      );
      await Promise.resolve();
    };

    it('shows the priority as a neutral badge on the date row, heard as "Priority: Second"', () => {
      const element = mount(model({ priority: "Second", priorityRank: 2 }));
      const badge = $(element, "[data-priority]");
      const row = $(element, "[data-dates]");

      expect(badge.textContent).toBe("Second");
      expect(badge.className).toBe("chip priority");
      expect(badge.getAttribute("aria-hidden")).toBe("true");
      expect(badge.parentElement).toBe(row);
      expect(row.querySelector(".assistive").textContent).toBe(
        "Created 12 Sep, Start 24 Sep, Due 1 Oct, Priority: Second"
      );
    });

    it("shows no badge, and says nothing of it, when there is none", () => {
      const element = mount(model({ priority: null, priorityRank: null }));
      expect($(element, "[data-priority]")).toBeNull();
      expect($(element, "[data-dates] .assistive").textContent).not.toContain(
        "Priority"
      );
    });

    it("keeps the badge on a card with no dates", () => {
      const element = mount(
        model({
          createdAt: null,
          startDate: null,
          dueDate: null,
          priority: "Third",
          priorityRank: 3
        })
      );
      expect($(element, "[data-dates] .dates")).toBeNull();
      expect($(element, "[data-priority]").textContent).toBe("Third");
    });

    it("stays on the open card too, read-only, as on the public board", () => {
      const element = mount(
        Object.assign(model({ priority: "First", priorityRank: 1 }), {
          key: "WI-0003"
        }),
        { expandedKey: "WI-0003" }
      );
      expect($(element, "[data-priority]").textContent).toBe("First");
      expect($(element, "[data-field='priority']")).toBeNull();
    });

    it("offers the board's choices in order, then No priority, with the saved one chosen", () => {
      const element = editable();
      const choices = Array.from(select(element).querySelectorAll("option"));

      expect(choices.map((c) => c.textContent.trim())).toStrictEqual([
        "First",
        "Second",
        "Third",
        "No priority"
      ]);
      expect(choices.map((c) => c.value)).toStrictEqual(["P1", "P2", "P3", ""]);
      expect(choices.map((c) => c.selected)).toStrictEqual([
        false,
        true,
        false,
        false
      ]);
    });

    it("chooses No priority when there is none", () => {
      const element = editable({ priority: null, priorityRank: null });
      const chosen = Array.from(
        select(element).querySelectorAll("option")
      ).find((c) => c.selected);
      expect(chosen.value).toBe("");
    });

    it("sits between the dates and Save", () => {
      const element = editable();
      const stops = Array.from(
        $(element, "form").querySelectorAll("input, select, button")
      ).map((node) => node.dataset.field || node.dataset.action);
      expect(stops).toStrictEqual([
        "title",
        "startDate",
        "dueDate",
        "priority",
        "save",
        "cancel"
      ]);
    });

    it("sends the choice's value, and an empty string for No priority", async () => {
      const element = editable();
      const handler = jest.fn();
      element.addEventListener("save", handler);

      choose(element, "P3");
      await submit(element);
      expect(handler.mock.calls[0][0].detail.priority).toBe("P3");

      choose(element, "");
      await submit(element);
      expect(handler.mock.calls[1][0].detail.priority).toBe("");
    });

    it("sends the saved priority unchanged when only the title changed", async () => {
      const element = editable();
      const handler = jest.fn();
      element.addEventListener("save", handler);
      const title = $(element, "[data-field='title']");
      title.value = "Renamed";
      title.dispatchEvent(new CustomEvent("input"));
      await submit(element);
      expect(handler.mock.calls[0][0].detail).toMatchObject({
        title: "Renamed",
        priority: "P2"
      });
    });

    it("has no priority editor for a source without one, and sends none", async () => {
      const element = editable({ supportsPriority: false });
      const handler = jest.fn();
      element.addEventListener("save", handler);
      expect(select(element)).toBeNull();
      await submit(element);
      expect("priority" in handler.mock.calls[0][0].detail).toBe(false);
    });

    it("shows the server's priority error beside the select", () => {
      const element = editable(
        {},
        {
          feedback: {
            key: "a0B1",
            tone: "error",
            message: "Nothing was saved.",
            fieldErrors: { priority: "Source A does not hold a priority." }
          }
        }
      );
      expect($(element, "[data-error='priority']").textContent.trim()).toBe(
        "Source A does not hold a priority."
      );
      expect(select(element).getAttribute("aria-invalid")).toBe("true");
    });

    it("is accessible closed with a badge, and open with the editor and an error", async () => {
      await expect(
        mount(model({ priority: "First", priorityRank: 1 }))
      ).toBeAccessible();
      await expect(
        editable(
          {},
          {
            feedback: {
              key: "a0B1",
              tone: "error",
              message: "Nothing was saved.",
              fieldErrors: { priority: "Source A does not hold a priority." }
            }
          }
        )
      ).toBeAccessible();
    });
  });
});
