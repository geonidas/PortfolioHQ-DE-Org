/**
 * The page's own job: read the content, show only the sections that have something in them, keep
 * the navigation in step with that, turn file names into addresses, and scroll. Each section is
 * tested on its own; this holds the wiring between them.
 *
 * The page is shown a half-empty portfolio by overwriting exports of the real content module for
 * one test and putting them back after. That is deliberate rather than jest.mock: the page reads
 * the exports when it is built, so a change made before mount is seen, and there is no need to
 * reset modules - which would not reset jsdom's custom element registry, and the second mount of
 * the same tag would fail.
 */
import { createElement } from "lwc";
import PortfolioPage from "c/portfolioPage";

// require, not an import: the exports are written to below, and an ES namespace is read-only.
// It is the same module object the page reads, because nothing here resets the registry.
const content = require("c/portfolioContent");

const BASE = { ...content };

function mount(overrides = {}) {
  // From the real content every time, so a test that mounts twice does not carry the first
  // mount's overrides into the second.
  Object.assign(content, BASE, overrides);
  const element = createElement("c-portfolio-page", { is: PortfolioPage });
  document.body.appendChild(element);
  return element;
}

const query = (element, selector) => element.shadowRoot.querySelector(selector);
const navLinks = (element) =>
  query(element, "c-portfolio-nav").links.map((link) => link.id);

describe("c-portfolio-page", () => {
  beforeEach(() => {
    window.scrollTo = jest.fn();
    Element.prototype.scrollIntoView = jest.fn();
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    Object.assign(content, BASE);
  });

  it("shows every section of the shipped content, with a navigation entry for each", () => {
    const element = mount();
    [
      "c-portfolio-nav",
      "c-portfolio-hero",
      "c-portfolio-projects",
      "c-portfolio-about",
      "c-portfolio-footer"
    ].forEach((tag) => expect(query(element, tag)).not.toBeNull());
    expect(navLinks(element)).toStrictEqual(["projects", "about", "contact"]);
  });

  it("puts the work before the person: hero, then projects, then about, then the footer", () => {
    const element = mount();
    const order = Array.from(
      element.shadowRoot.querySelectorAll(
        "c-portfolio-hero, c-portfolio-projects, c-portfolio-about, c-portfolio-footer"
      )
    ).map((node) => node.localName);
    expect(order).toStrictEqual([
      "c-portfolio-hero",
      "c-portfolio-projects",
      "c-portfolio-about",
      "c-portfolio-footer"
    ]);
  });

  it("has no skills or experience section to keep current", () => {
    const element = mount();
    expect(query(element, "c-portfolio-skills")).toBeNull();
    expect(query(element, "c-portfolio-experience")).toBeNull();
  });

  it("puts the hero in a main landmark and the footer after it", () => {
    const element = mount();
    expect(query(element, "main c-portfolio-hero")).not.toBeNull();
    expect(query(element, "main c-portfolio-footer")).toBeNull();
    expect(query(element, "c-portfolio-footer")).not.toBeNull();
  });

  it("leaves a section out of the page and out of the navigation when its content is empty", () => {
    const noAbout = mount({ ABOUT: { summary: [] } });
    expect(query(noAbout, "c-portfolio-about")).toBeNull();
    expect(navLinks(noAbout)).toStrictEqual(["projects", "contact"]);

    const noProjects = mount({ PROJECTS: [] });
    expect(query(noProjects, "c-portfolio-projects")).toBeNull();
    expect(navLinks(noProjects)).toStrictEqual(["about", "contact"]);
    // The hero's button has nowhere to go, so it is told there are no projects.
    expect(query(noProjects, "c-portfolio-hero").hasProjects).toBe(false);
  });

  it("always keeps Contact, because the footer is always there", () => {
    const element = mount({ ABOUT: { summary: [] }, PROJECTS: [] });
    expect(navLinks(element)).toStrictEqual(["contact"]);
  });

  describe("addresses in the static resource", () => {
    it("builds the picture's from the file named in the content, or leaves it empty", () => {
      const withPhoto = mount({
        PROFILE: { ...BASE.PROFILE, photo: "me.jpg" }
      });
      expect(query(withPhoto, "c-portfolio-hero").photoUrl).toMatch(
        /\/me\.jpg$/
      );
      const without = mount({ PROFILE: { ...BASE.PROFILE, photo: "" } });
      expect(query(without, "c-portfolio-hero").photoUrl).toBe("");
    });

    it("resolves each project's media file to an address, and keeps the rest of it", () => {
      const element = mount({
        PROJECTS: [
          {
            id: "p",
            title: "P",
            summary: "S",
            links: [],
            media: [{ file: "shot.png", device: "desktop", alt: "A shot" }]
          }
        ]
      });
      const [project] = query(element, "c-portfolio-projects").projects;
      expect(project.media).toHaveLength(1);
      expect(project.media[0].url).toMatch(/\/shot\.png$/);
      expect(project.media[0]).toMatchObject({
        device: "desktop",
        alt: "A shot"
      });
      expect(project.media[0].file).toBeUndefined();
    });

    it("passes a project with no media through with an empty list", () => {
      const element = mount({
        PROJECTS: [{ id: "p", title: "P", summary: "S", links: [] }]
      });
      expect(query(element, "c-portfolio-projects").projects[0].media).toEqual(
        []
      );
    });

    it("gives the projects section its intro", () => {
      const element = mount({ PROJECTS_INTRO: "Look at these." });
      expect(query(element, "c-portfolio-projects").intro).toBe(
        "Look at these."
      );
    });
  });

  it("derives the initials from the first two words of the name", () => {
    const initials = (name) =>
      query(mount({ PROFILE: { ...BASE.PROFILE, name } }), "c-portfolio-hero")
        .initials;
    expect(initials("Ada Lovelace")).toBe("AL");
    expect(initials("ada byron king lovelace")).toBe("AB");
    expect(initials("Ada")).toBe("A");
  });

  it("gives the footer the email address from the profile links", () => {
    const footer = query(mount(), "c-portfolio-footer");
    expect(footer.emailUrl).toBe(
      BASE.PROFILE_LINKS.find((link) => link.id === "email").url
    );
  });

  describe("scrolling", () => {
    it("scrolls a section into view when the bar asks for it", () => {
      const element = mount();
      query(element, "c-portfolio-nav").dispatchEvent(
        new CustomEvent("navigate", { detail: { id: "projects" } })
      );
      expect(Element.prototype.scrollIntoView).toHaveBeenCalledTimes(1);
      expect(Element.prototype.scrollIntoView.mock.instances[0]).toBe(
        query(element, "c-portfolio-projects")
      );
    });

    it("answers the hero's button the same way", () => {
      const element = mount();
      query(element, "c-portfolio-hero").dispatchEvent(
        new CustomEvent("navigate", { detail: { id: "projects" } })
      );
      expect(Element.prototype.scrollIntoView.mock.instances[0]).toBe(
        query(element, "c-portfolio-projects")
      );
    });

    it("goes to the top of the window for the name", () => {
      const element = mount();
      query(element, "c-portfolio-nav").dispatchEvent(
        new CustomEvent("navigate", { detail: { id: "top" } })
      );
      expect(window.scrollTo).toHaveBeenCalledWith(
        expect.objectContaining({ top: 0 })
      );
      expect(Element.prototype.scrollIntoView).not.toHaveBeenCalled();
    });

    it("does nothing for a section that is not on the page", () => {
      const element = mount({ ABOUT: { summary: [] } });
      query(element, "c-portfolio-nav").dispatchEvent(
        new CustomEvent("navigate", { detail: { id: "about" } })
      );
      expect(Element.prototype.scrollIntoView).not.toHaveBeenCalled();
    });

    it("scrolls at once, not smoothly, for a visitor who asked for less motion", () => {
      window.matchMedia = jest.fn().mockReturnValue({ matches: true });
      const element = mount();
      query(element, "c-portfolio-nav").dispatchEvent(
        new CustomEvent("navigate", { detail: { id: "about" } })
      );
      expect(Element.prototype.scrollIntoView).toHaveBeenCalledWith(
        expect.objectContaining({ behavior: "auto" })
      );
      delete window.matchMedia;
    });
  });

  describe("the section in view", () => {
    let callback;
    let observed;
    let disconnect;

    beforeEach(() => {
      observed = [];
      disconnect = jest.fn();
      global.IntersectionObserver = jest.fn((cb) => {
        callback = cb;
        return { observe: (node) => observed.push(node), disconnect };
      });
    });

    afterEach(() => {
      delete global.IntersectionObserver;
    });

    it("watches every section that is on the page, and the footer", () => {
      mount();
      expect(observed.map((node) => node.dataset.section)).toStrictEqual([
        "projects",
        "about",
        "contact"
      ]);
    });

    it("marks the section that crosses the band as active, and clears it at the top", async () => {
      const element = mount();
      const nav = query(element, "c-portfolio-nav");
      callback([{ isIntersecting: true, target: observed[1] }]);
      await Promise.resolve();
      expect(nav.active).toBe("about");
      window.scrollY = 0;
      callback([{ isIntersecting: false, target: observed[1] }]);
      await Promise.resolve();
      expect(nav.active).toBe("");
    });

    it("stops watching when the page is removed", () => {
      const element = mount();
      document.body.removeChild(element);
      expect(disconnect).toHaveBeenCalled();
    });
  });

  it("is accessible", async () => {
    await expect(mount()).toBeAccessible();
  });
});
