import { createElement } from "lwc";
import PortfolioNav from "c/portfolioNav";

const LINKS = [
  { id: "about", label: "About" },
  { id: "projects", label: "Projects" },
  { id: "contact", label: "Contact" }
];

function mount(props) {
  const element = createElement("c-portfolio-nav", { is: PortfolioNav });
  Object.assign(
    element,
    {
      name: "Ada Lovelace",
      initials: "AL",
      links: LINKS,
      resumeUrl: "https://example.com/resume.pdf"
    },
    props
  );
  document.body.appendChild(element);
  return element;
}

const query = (element, selector) => element.shadowRoot.querySelector(selector);
const button = (element) => query(element, "[data-menu-button]");

async function flush() {
  await Promise.resolve();
}

describe("c-portfolio-nav", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("shows the name and initials, and a link to each section it is given", () => {
    const element = mount();
    expect(query(element, ".brand-name").textContent).toBe("Ada Lovelace");
    expect(query(element, ".mark").textContent).toBe("AL");
    const labels = Array.from(element.shadowRoot.querySelectorAll(".link")).map(
      (a) => a.textContent
    );
    expect(labels).toStrictEqual(["About", "Projects", "Contact"]);
    // Synthetic shadow rewrites a fragment-only href to match its mangled ids ("#about-0"), so
    // the test pins the anchor, not the suffix. Every click is intercepted either way.
    expect(
      query(element, '.link[data-id="about"]').getAttribute("href")
    ).toMatch(/^#about/);
  });

  it("marks only the section in view as current", () => {
    const element = mount({ active: "projects" });
    const current = Array.from(
      element.shadowRoot.querySelectorAll('.link[aria-current="true"]')
    ).map((a) => a.dataset.id);
    expect(current).toStrictEqual(["projects"]);
  });

  it("marks nothing while the hero is in view", () => {
    const element = mount({ active: "" });
    expect(element.shadowRoot.querySelectorAll("[aria-current]")).toHaveLength(
      0
    );
  });

  it("raises navigate with the section id and keeps the browser from following the hash", () => {
    const element = mount();
    const handler = jest.fn();
    element.addEventListener("navigate", handler);
    const click = new MouseEvent("click", { bubbles: true, cancelable: true });
    query(element, '.link[data-id="projects"]').dispatchEvent(click);
    expect(click.defaultPrevented).toBe(true);
    expect(handler).toHaveBeenCalledTimes(1);
    expect(handler.mock.calls[0][0].detail).toStrictEqual({ id: "projects" });
  });

  it("sends the name back to the top", () => {
    const element = mount();
    const handler = jest.fn();
    element.addEventListener("navigate", handler);
    query(element, "[data-brand]").click();
    expect(handler.mock.calls[0][0].detail).toStrictEqual({ id: "top" });
  });

  it("links the résumé in a new tab, and hides it when there is none", () => {
    const shown = query(mount(), "[data-resume]");
    expect(shown.getAttribute("href")).toBe("https://example.com/resume.pdf");
    expect(shown.getAttribute("target")).toBe("_blank");
    expect(shown.getAttribute("rel")).toBe("noopener noreferrer");
    expect(query(mount({ resumeUrl: "" }), "[data-resume]")).toBeNull();
  });

  describe("menu", () => {
    it("starts closed, and the button says so", () => {
      const element = mount();
      expect(button(element).getAttribute("aria-expanded")).toBe("false");
      expect(query(element, "nav").classList.contains("open")).toBe(false);
      expect(query(element, ".menu-button .assistive").textContent).toBe(
        "Open menu"
      );
    });

    it("opens and closes with the button, keeping aria-expanded and the label true", async () => {
      const element = mount();
      button(element).click();
      await flush();
      expect(button(element).getAttribute("aria-expanded")).toBe("true");
      expect(query(element, "nav").classList.contains("open")).toBe(true);
      expect(query(element, ".menu-button .assistive").textContent).toBe(
        "Close menu"
      );
      button(element).click();
      await flush();
      expect(button(element).getAttribute("aria-expanded")).toBe("false");
    });

    it("closes on Escape and gives focus back to the button", async () => {
      const element = mount();
      button(element).click();
      await flush();
      query(element, "header").dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true })
      );
      await flush();
      expect(button(element).getAttribute("aria-expanded")).toBe("false");
      expect(element.shadowRoot.activeElement).toBe(button(element));
    });

    it("ignores Escape while it is closed", async () => {
      const element = mount();
      query(element, "header").dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true })
      );
      await flush();
      expect(button(element).getAttribute("aria-expanded")).toBe("false");
    });

    it("closes when a link is chosen", async () => {
      const element = mount();
      button(element).click();
      await flush();
      query(element, '.link[data-id="about"]').click();
      await flush();
      expect(button(element).getAttribute("aria-expanded")).toBe("false");
    });
  });

  it("is accessible, closed and open", async () => {
    const element = mount({ active: "about" });
    await expect(element).toBeAccessible();
    button(element).click();
    await flush();
    await expect(element).toBeAccessible();
  });
});
