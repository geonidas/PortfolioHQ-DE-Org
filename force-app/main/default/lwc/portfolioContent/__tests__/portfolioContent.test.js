/**
 * The content file is edited by hand and read by the page as-is, so this holds it to the shape the
 * components assume. A typo in a link, a duplicated id, a label that promises a live version with
 * nothing to open, or a picture that is not in the static resource fails here, before a deploy,
 * instead of showing on a public page.
 */
import { createElement } from "lwc";
import PortfolioIcon from "c/portfolioIcon";
import {
  PROFILE,
  RESUME,
  PROFILE_LINKS,
  PROJECTS_INTRO,
  PROJECTS,
  ABOUT,
  CONTACT
} from "c/portfolioContent";

const fs = require("fs");
const path = require("path");

const ASSETS = path.resolve(
  __dirname,
  "../../../staticresources/portfolio_assets"
);

/** A page link is either a web address or a mail address; nothing else is allowed through. */
const SAFE_URL = /^(https:\/\/[^\s]+|mailto:[^\s@]+@[^\s@]+)$/;

/** The access levels portfolioProjects labels. */
const ACCESS_LEVELS = ["interactive", "view", "video", "screenshots"];
/** The ones that promise a live version a visitor can open. */
const LIVE_LEVELS = ["interactive", "view"];

const nonEmpty = (value) => typeof value === "string" && value.trim() !== "";
const inAssets = (file) => fs.existsSync(path.join(ASSETS, file));

function iconPath(name) {
  const icon = createElement("c-portfolio-icon", { is: PortfolioIcon });
  icon.name = name;
  document.body.appendChild(icon);
  return icon.shadowRoot.querySelector("path").getAttribute("d");
}

describe("portfolioContent", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("names the owner and what they do", () => {
    expect(nonEmpty(PROFILE.name)).toBe(true);
    expect(nonEmpty(PROFILE.headline)).toBe(true);
    expect(nonEmpty(PROFILE.intro)).toBe(true);
  });

  it("keeps the profile picture inside the static resource, or leaves it empty", () => {
    expect(!PROFILE.photo || inAssets(PROFILE.photo)).toBe(true);
  });

  it("uses only https and mailto addresses, so a mistyped scheme cannot ship", () => {
    const urls = [
      RESUME.url,
      ...PROFILE_LINKS.map((link) => link.url),
      ...PROJECTS.flatMap((project) => project.links.map((link) => link.url))
    ].filter(Boolean);
    expect(urls.length).toBeGreaterThan(0);
    urls.forEach((url) => expect(url).toMatch(SAFE_URL));
  });

  it("gives every profile link a unique id, a label and an icon that exists", () => {
    const ids = PROFILE_LINKS.map((link) => link.id);
    expect(new Set(ids).size).toBe(ids.length);
    const arrow = iconPath("arrow");
    PROFILE_LINKS.forEach((link) => {
      expect(nonEmpty(link.label)).toBe(true);
      // An unknown name falls back to the arrow, so a typo shows up as the arrow.
      expect(iconPath(link.icon)).not.toBe(arrow);
    });
  });

  it("has an email link, because the footer's button is built from it", () => {
    expect(PROFILE_LINKS.some((link) => link.id === "email")).toBe(true);
  });

  describe("projects", () => {
    it("has at least one, because the page is a showcase of them", () => {
      expect(PROJECTS.length).toBeGreaterThan(0);
      expect(nonEmpty(PROJECTS_INTRO)).toBe(true);
    });

    it("gives each a unique id, a title and a summary", () => {
      const ids = PROJECTS.map((project) => project.id);
      expect(new Set(ids).size).toBe(ids.length);
      PROJECTS.forEach((project) => {
        expect(nonEmpty(project.title)).toBe(true);
        expect(nonEmpty(project.summary)).toBe(true);
        project.links.forEach((link) =>
          expect(nonEmpty(link.label)).toBe(true)
        );
      });
    });

    it("names an access level that exists, or none", () => {
      PROJECTS.filter((project) => project.access).forEach((project) =>
        expect(ACCESS_LEVELS).toContain(project.access)
      );
    });

    it("never promises a live version it does not link to", () => {
      PROJECTS.filter((project) =>
        LIVE_LEVELS.includes(project.access)
      ).forEach((project) => {
        const demo = project.links.find(
          (link) => link.kind === "demo" && link.url
        );
        expect(demo).toBeDefined();
      });
    });

    it("keeps every picture in the static resource, on a known device, with alt text", () => {
      const media = PROJECTS.flatMap((project) => project.media || []);
      expect(media.length).toBeGreaterThan(0);
      media.forEach((item) => {
        expect(inAssets(item.file)).toBe(true);
        expect(["desktop", "phone"]).toContain(item.device);
        // Alt text is what a visitor who cannot see the picture is told, so it says something.
        expect(item.alt.trim().split(/\s+/).length).toBeGreaterThan(3);
      });
    });

    it("has at most one featured project, because one is shown wide", () => {
      expect(PROJECTS.filter((project) => project.featured).length).toBe(1);
    });
  });

  it("fills every list entry the components read", () => {
    ABOUT.summary.forEach((paragraph) =>
      expect(nonEmpty(paragraph)).toBe(true)
    );
    expect(nonEmpty(CONTACT.heading)).toBe(true);
  });

  it("holds no work history, skills or certifications: those live on the résumé", () => {
    const exported = Object.keys(jest.requireActual("c/portfolioContent"));
    expect(
      exported.filter((name) => /EXPERIENCE|SKILL|CERT/.test(name))
    ).toEqual([]);
  });
});
