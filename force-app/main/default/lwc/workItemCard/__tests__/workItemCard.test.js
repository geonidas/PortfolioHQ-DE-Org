import { createElement } from "lwc";
import WorkItemCard from "c/workItemCard";

function card(overrides) {
  return Object.assign(
    {
      id: "w1",
      name: "WI-0000",
      externalKey: "DOPP-1",
      status: "To Do",
      isUnmappedStatus: false,
      type: "Story",
      hasType: true,
      syncStatus: "Synced",
      showSyncFlag: false,
      syncClass: "sync-flag sync-pending",
      syncTitle: "",
      storyPoints: null,
      hasPoints: false,
      description: null,
      hasDescription: false,
      projectLabel: "Portfolio HQ",
      hasProjectLabel: true,
      parentId: null,
      showParentNote: false,
      parentNote: null,
      children: [],
      hasChildren: false,
      cssClass: ""
    },
    overrides
  );
}

function mount(data) {
  const element = createElement("c-work-item-card", { is: WorkItemCard });
  element.card = data;
  document.body.appendChild(element);
  return element;
}

describe("c-work-item-card", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("omits the badge entirely when the type is unknown", () => {
    const element = mount(card({ type: "Unspecified", hasType: false }));
    // Not an empty badge and not a placeholder - the element is simply absent, so the card
    // reads as untyped rather than as broken.
    expect(element.shadowRoot.querySelector(".badge")).toBeNull();
    expect(element.shadowRoot.querySelector(".key").textContent).toBe("DOPP-1");
  });

  it("marks a card whose status Jira reported but we cannot map", () => {
    const element = mount(
      card({ isUnmappedStatus: true, cssClass: "is-unmapped" })
    );
    expect(element.shadowRoot.querySelector("article").className).toContain(
      "is-unmapped"
    );
  });

  it("says when no description has synced rather than leaving a gap", () => {
    const element = mount(card({ hasDescription: false }));
    expect(element.shadowRoot.querySelector(".desc-none").textContent).toBe(
      "No description synced"
    );
  });

  it("announces itself as operable and raises select on click", () => {
    const element = mount(card());
    const handler = jest.fn();
    element.addEventListener("select", handler);

    const article = element.shadowRoot.querySelector("article");
    expect(article.getAttribute("role")).toBe("button");
    expect(article.getAttribute("tabindex")).toBe("0");

    article.click();
    expect(handler).toHaveBeenCalled();
    expect(handler.mock.calls[0][0].detail.id).toBe("w1");
  });

  it("is operable by keyboard, not only by mouse", () => {
    const element = mount(card());
    const handler = jest.fn();
    element.addEventListener("select", handler);

    element.shadowRoot
      .querySelector("article")
      .dispatchEvent(
        new KeyboardEvent("keydown", { key: "Enter", bubbles: true })
      );
    expect(handler).toHaveBeenCalled();
  });
});
