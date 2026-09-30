import { createElement } from "lwc";
import PortfolioAbout from "c/portfolioAbout";

function mount(summary = ["First paragraph.", "Second paragraph."]) {
  const element = createElement("c-portfolio-about", { is: PortfolioAbout });
  element.summary = summary;
  document.body.appendChild(element);
  return element;
}

const texts = (element, selector) =>
  Array.from(element.shadowRoot.querySelectorAll(selector)).map(
    (node) => node.textContent
  );

describe("c-portfolio-about", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("renders the summary as one paragraph per entry, in order", () => {
    expect(texts(mount(), ".paragraph")).toStrictEqual([
      "First paragraph.",
      "Second paragraph."
    ]);
  });

  it("titles the section", () => {
    expect(texts(mount(), "h2")).toStrictEqual(["A bit about me"]);
  });

  it("holds prose only: no counts, tiles or lists of skills to keep current", () => {
    const element = mount();
    expect(element.shadowRoot.querySelector("ul, ol, table")).toBeNull();
  });

  it("shows the heading alone, without failing, when it is given nothing", () => {
    const element = mount(null);
    expect(element.shadowRoot.querySelectorAll(".paragraph")).toHaveLength(0);
  });

  it("is accessible", async () => {
    await expect(mount()).toBeAccessible();
  });
});
