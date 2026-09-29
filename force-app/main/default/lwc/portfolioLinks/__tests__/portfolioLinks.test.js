import { createElement } from "lwc";
import PortfolioLinks from "c/portfolioLinks";

const LINKS = [
  {
    id: "github",
    label: "GitHub",
    icon: "github",
    url: "https://github.com/someone"
  },
  {
    id: "email",
    label: "Email",
    icon: "mail",
    url: "mailto:someone@example.com"
  },
  { id: "trailhead", label: "Trailhead", icon: "trailhead", url: "" }
];

function mount(props) {
  const element = createElement("c-portfolio-links", { is: PortfolioLinks });
  Object.assign(element, { links: LINKS }, props);
  document.body.appendChild(element);
  return element;
}

const link = (element, id) =>
  element.shadowRoot.querySelector(`a[data-link="${id}"]`);

describe("c-portfolio-links", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("leaves out a link that has no url, and keeps the order of the rest", () => {
    const element = mount();
    const shown = Array.from(element.shadowRoot.querySelectorAll("a")).map(
      (a) => a.dataset.link
    );
    expect(shown).toStrictEqual(["github", "email"]);
  });

  it("opens a web link in a new tab without handing it the opener, and says so", () => {
    const github = link(mount(), "github");
    expect(github.getAttribute("href")).toBe("https://github.com/someone");
    expect(github.getAttribute("target")).toBe("_blank");
    expect(github.getAttribute("rel")).toBe("noopener noreferrer");
    expect(github.querySelector(".assistive").textContent).toBe(
      "(opens in a new tab)"
    );
  });

  it("opens a mailto: link in the mail app, in the same tab, with no new-tab warning", () => {
    const email = link(mount(), "email");
    expect(email.getAttribute("href")).toBe("mailto:someone@example.com");
    expect(email.hasAttribute("target")).toBe(false);
    expect(email.hasAttribute("rel")).toBe(false);
    expect(email.querySelector(".assistive")).toBeNull();
  });

  it("names each link by its label, with the icon left out of the name", () => {
    const github = link(mount(), "github");
    expect(github.querySelector("c-portfolio-icon")).not.toBeNull();
    expect(github.textContent).toContain("GitHub");
  });

  it("uses the dark treatment only when asked", () => {
    expect(
      mount().shadowRoot.querySelector("ul").classList.contains("dark")
    ).toBe(false);
    expect(
      mount({ tone: "dark" }).shadowRoot.querySelector("ul").classList
    ).toContain("dark");
  });

  it("shows an empty list without failing when it is given nothing", () => {
    const element = mount({ links: undefined });
    expect(element.shadowRoot.querySelectorAll("a")).toHaveLength(0);
  });

  it("is accessible", async () => {
    await expect(mount()).toBeAccessible();
  });
});
