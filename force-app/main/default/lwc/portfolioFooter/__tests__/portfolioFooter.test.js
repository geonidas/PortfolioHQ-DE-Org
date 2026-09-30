import { createElement } from "lwc";
import PortfolioFooter from "c/portfolioFooter";

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
  }
];

function mount(props) {
  const element = createElement("c-portfolio-footer", {
    is: PortfolioFooter
  });
  Object.assign(
    element,
    {
      name: "Ada Lovelace",
      heading: "Let's talk",
      text: "Write to me.",
      emailUrl: "mailto:someone@example.com",
      links: LINKS
    },
    props
  );
  document.body.appendChild(element);
  return element;
}

const query = (element, selector) => element.shadowRoot.querySelector(selector);

describe("c-portfolio-footer", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("shows the heading and the text, and the email as a button", () => {
    const element = mount();
    expect(query(element, "h2").textContent).toBe("Let's talk");
    expect(query(element, ".text").textContent).toBe("Write to me.");
    expect(query(element, '[data-action="email"]').getAttribute("href")).toBe(
      "mailto:someone@example.com"
    );
  });

  it("does not repeat the email among the profile links while the button is there", () => {
    const shown = query(mount(), "c-portfolio-links").links.map((l) => l.id);
    expect(shown).toStrictEqual(["github"]);
  });

  it("keeps the email among the profile links when there is no button", () => {
    const element = mount({ emailUrl: "" });
    expect(query(element, '[data-action="email"]')).toBeNull();
    expect(
      query(element, "c-portfolio-links").links.map((l) => l.id)
    ).toStrictEqual(["github", "email"]);
  });

  it("uses the dark treatment for the links, because the footer is navy", () => {
    expect(query(mount(), "c-portfolio-links").tone).toBe("dark");
  });

  it("closes with a copyright for the current year", () => {
    expect(query(mount(), ".copyright").textContent).toBe(
      `© ${new Date().getFullYear()} Ada Lovelace`
    );
  });

  it("leaves out the text when there is none", () => {
    expect(query(mount({ text: "" }), ".text")).toBeNull();
  });

  it("is accessible", async () => {
    await expect(mount()).toBeAccessible();
  });
});
