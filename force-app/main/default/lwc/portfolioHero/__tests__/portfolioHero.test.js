import { createElement } from "lwc";
import PortfolioHero from "c/portfolioHero";

const LINKS = [
  {
    id: "github",
    label: "GitHub",
    icon: "github",
    url: "https://github.com/someone"
  }
];

function mount(props) {
  const element = createElement("c-portfolio-hero", { is: PortfolioHero });
  Object.assign(
    element,
    {
      name: "Ada Lovelace",
      initials: "AL",
      headline: "Salesforce Developer",
      intro: "I build things.",
      location: "London",
      availability: "Open to work",
      photoUrl: "/assets/ada.jpg",
      resumeUrl: "https://example.com/resume.pdf",
      links: LINKS,
      hasProjects: true
    },
    props
  );
  document.body.appendChild(element);
  return element;
}

const query = (element, selector) => element.shadowRoot.querySelector(selector);

async function flush() {
  await Promise.resolve();
}

describe("c-portfolio-hero", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("makes the name the page's one h1, over the headline and introduction", () => {
    const element = mount();
    expect(element.shadowRoot.querySelectorAll("h1")).toHaveLength(1);
    expect(query(element, "h1").textContent).toBe("Ada Lovelace");
    expect(query(element, ".headline").textContent).toBe(
      "Salesforce Developer"
    );
    expect(query(element, ".intro").textContent).toBe("I build things.");
  });

  it("shows the photo with alt text that names the person", () => {
    const element = mount();
    const photo = query(element, "[data-photo]");
    expect(photo.getAttribute("src")).toBe("/assets/ada.jpg");
    expect(photo.getAttribute("alt")).toBe("Portrait of Ada Lovelace");
    expect(query(element, "[data-initials]")).toBeNull();
  });

  it("shows the initials when there is no photo, still named for a screen reader", () => {
    const element = mount({ photoUrl: "" });
    expect(query(element, "[data-photo]")).toBeNull();
    const initials = query(element, "[data-initials]");
    expect(initials.textContent.trim()).toBe("AL");
    expect(initials.getAttribute("role")).toBe("img");
    expect(initials.getAttribute("aria-label")).toBe(
      "Portrait of Ada Lovelace"
    );
  });

  it("falls back to the initials when the photo fails to load", async () => {
    const element = mount();
    query(element, "[data-photo]").dispatchEvent(new CustomEvent("error"));
    await flush();
    expect(query(element, "[data-photo]")).toBeNull();
    expect(query(element, "[data-initials]")).not.toBeNull();
  });

  it("links the résumé in a new tab, and drops the button when there is none", () => {
    const resume = query(mount(), '[data-action="resume"]');
    expect(resume.getAttribute("href")).toBe("https://example.com/resume.pdf");
    expect(resume.getAttribute("target")).toBe("_blank");
    expect(resume.getAttribute("rel")).toBe("noopener noreferrer");
    expect(
      query(mount({ resumeUrl: "" }), '[data-action="resume"]')
    ).toBeNull();
  });

  it("offers the projects button only when there are projects, and raises navigate", () => {
    const element = mount();
    const handler = jest.fn();
    element.addEventListener("navigate", handler);
    const click = new MouseEvent("click", { bubbles: true, cancelable: true });
    query(element, '[data-action="projects"]').dispatchEvent(click);
    expect(click.defaultPrevented).toBe(true);
    expect(handler.mock.calls[0][0].detail).toStrictEqual({ id: "projects" });
    expect(
      query(mount({ hasProjects: false }), '[data-action="projects"]')
    ).toBeNull();
  });

  it("leaves out availability and location when they are empty", () => {
    const element = mount({ availability: "", location: "" });
    expect(query(element, "[data-availability]")).toBeNull();
    expect(query(element, "[data-location]")).toBeNull();
  });

  it("hands the profile links to c-portfolio-links", () => {
    expect(query(mount(), "c-portfolio-links").links).toStrictEqual(LINKS);
  });

  it("is accessible with a photo, and with the initials", async () => {
    await expect(mount()).toBeAccessible();
    await expect(mount({ photoUrl: "" })).toBeAccessible();
  });
});
