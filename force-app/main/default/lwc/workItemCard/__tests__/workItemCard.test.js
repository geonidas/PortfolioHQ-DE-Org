import { createElement } from "lwc";
import WorkItemCard from "c/workItemCard";

function card(overrides) {
  return Object.assign(
    {
      id: "w1",
      name: "WI-0000",
      title: "Reconcile the nightly Jira pull",
      hasTitle: true,
      heading: "Reconcile the nightly Jira pull",
      headingClass: "heading",
      identLabel: "WI-0000 · DOPP-1",
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
      hasMeta: true,
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
    expect(element.shadowRoot.querySelector(".num").textContent).toBe(
      "WI-0000 · DOPP-1"
    );
  });

  it("leads with the title, not the key", () => {
    const element = mount(card());
    const heading = element.shadowRoot.querySelector("h3.heading");
    expect(heading.textContent).toBe("Reconcile the nightly Jira pull");
    expect(heading.className).not.toContain("heading-fallback");
    // The key is not gone, it is demoted: it sits with the auto number below the title.
    expect(element.shadowRoot.querySelector(".num").textContent).toBe(
      "WI-0000 · DOPP-1"
    );
    // Nothing above the heading in the rendered order.
    expect(
      element.shadowRoot.querySelector("article").firstElementChild.className
    ).toContain("head");
  });

  it("falls back to the key, visibly toned down, when no title has synced", () => {
    const element = mount(
      card({
        title: null,
        hasTitle: false,
        heading: "DOPP-1",
        headingClass: "heading heading-fallback",
        identLabel: "WI-0000"
      })
    );
    const heading = element.shadowRoot.querySelector("h3.heading");
    expect(heading.textContent).toBe("DOPP-1");
    // Styled as a stand-in so an untitled card does not read as a titled one.
    expect(heading.className).toContain("heading-fallback");
    // And not repeated underneath - the key is already the heading.
    expect(element.shadowRoot.querySelector(".num").textContent).toBe(
      "WI-0000"
    );
  });

  it("drops the meta row rather than rendering it empty", () => {
    const element = mount(
      card({ hasPoints: false, hasProjectLabel: false, hasMeta: false })
    );
    expect(element.shadowRoot.querySelector(".meta")).toBeNull();
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

  // Build 08 gate: every rendered variant is held to sa11y's rule set, not just the default,
  // because a violation that only exists on a fallback heading or a sync flag would pass a
  // check of the plain card.
  describe("accessibility", () => {
    // The one known violation, pinned exactly rather than waived. The whole card is an
    // <article role="button">, which axe rejects (aria-allowed-role) and which also flattens
    // the heading inside it for a screen reader. Not patched here: a <div role="button"> would
    // satisfy the rule and keep the flattened heading. Build 08 step 7 replaces the clickable
    // card with a disclosure button in the card header, and this list must then be empty.
    const KNOWN = ["aria-allowed-role"];

    it("has no violation but the known one in its default form", async () => {
      await expect(mount(card())).toHaveOnlyKnownA11yViolations(KNOWN);
    });

    it("has no violation but the known one with a fallback heading, a sync flag and a parent note", async () => {
      const element = mount(
        card({
          title: null,
          hasTitle: false,
          heading: "DOPP-1",
          headingClass: "heading heading-fallback",
          identLabel: "WI-0000",
          syncStatus: "Pending",
          showSyncFlag: true,
          syncTitle: "Not reconciled: Pending",
          showParentNote: true,
          parentNote: "Child of DOPP-16"
        })
      );
      await expect(element).toHaveOnlyKnownA11yViolations(KNOWN);
    });

    it("has no violation but the known one with a description, points and an unmapped status", async () => {
      const element = mount(
        card({
          description: "Board cards grouped by status.",
          hasDescription: true,
          storyPoints: 3,
          hasPoints: true,
          isUnmappedStatus: true,
          cssClass: "is-unmapped",
          syncStatus: "Failed",
          showSyncFlag: true,
          syncClass: "sync-flag sync-failed"
        })
      );
      await expect(element).toHaveOnlyKnownA11yViolations(KNOWN);
    });
  });
});
