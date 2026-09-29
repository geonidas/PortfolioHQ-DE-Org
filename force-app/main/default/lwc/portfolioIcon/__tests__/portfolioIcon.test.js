import { createElement } from "lwc";
import PortfolioIcon from "c/portfolioIcon";

function mount(name) {
  const element = createElement("c-portfolio-icon", { is: PortfolioIcon });
  element.name = name;
  document.body.appendChild(element);
  return element;
}

const svg = (element) => element.shadowRoot.querySelector("svg");
const path = (element) => element.shadowRoot.querySelector("path");

describe("c-portfolio-icon", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("draws a different shape for each name", () => {
    const names = [
      "github",
      "linkedin",
      "trailhead",
      "mail",
      "download",
      "pin",
      "eye",
      "play",
      "cursor",
      "image"
    ];
    const shapes = names.map((name) => path(mount(name)).getAttribute("d"));
    expect(new Set(shapes).size).toBe(names.length);
  });

  it("falls back to the arrow for a name it does not know", () => {
    expect(path(mount("no-such-icon")).getAttribute("d")).toBe(
      path(mount("arrow")).getAttribute("d")
    );
  });

  it("fills brand marks and outlines the rest", () => {
    expect(svg(mount("github")).classList.contains("glyph")).toBe(true);
    expect(svg(mount("mail")).classList.contains("outline")).toBe(true);
  });

  it("cuts the letters out of the LinkedIn square with the even-odd rule", () => {
    expect(path(mount("linkedin")).getAttribute("fill-rule")).toBe("evenodd");
    expect(path(mount("github")).getAttribute("fill-rule")).toBe("nonzero");
  });

  it("is decorative: hidden from assistive technology and not focusable", () => {
    const icon = svg(mount("github"));
    expect(icon.getAttribute("aria-hidden")).toBe("true");
    expect(icon.getAttribute("focusable")).toBe("false");
  });
});
