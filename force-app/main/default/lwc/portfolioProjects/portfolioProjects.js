import { LightningElement, api } from "lwc";

const LINK_ICONS = { demo: "external", source: "github", code: "code" };

/**
 * What a visitor can do with a project, as the label on its card. The content file promises one of
 * these per project, and portfolioContent.test.js holds the two that claim a live version to
 * having a link to it.
 */
const ACCESS = {
  interactive: { label: "Interactive demo", icon: "cursor" },
  view: { label: "Live, view-only", icon: "eye" },
  video: { label: "Video walkthrough", icon: "play" },
  screenshots: { label: "Screenshots only", icon: "image" }
};

/**
 * Project cards: the point of the page. A card shows the project in action first - a screenshot in
 * a browser frame, and a phone frame beside it when there is one - then what it is, how far a
 * visitor can go with it, what is worth trying, what it was built with, and where to open it.
 *
 * A project marked featured is shown wide at the head of the grid; the rest sit two to a row. Every
 * part but the title and summary is optional, so a card can be listed before its demo exists: no
 * media, no access label and no link leaves no hole. A picture that fails to load is dropped and
 * the card closes up around it.
 */
export default class PortfolioProjects extends LightningElement {
  /** A line under the heading; empty shows nothing. */
  @api intro = "";
  /**
   * [{ id, featured, title, summary, access, tryIt, tags, links: [{ kind, label, url }],
   *    media: [{ url, alt, device }] }]. url is a full address: the page builds it from the
   * static resource, so this component imports nothing.
   */
  @api projects = [];

  failedUrls = [];

  get hasIntro() {
    return Boolean(this.intro);
  }

  get cards() {
    const cards = (this.projects || []).map((project, index) => {
      const links = (project.links || [])
        .filter((link) => link.url)
        .map((link, i) => ({
          ...link,
          key: `p${index}-l${i}`,
          icon: LINK_ICONS[link.kind] || "arrow"
        }));
      const primary = links.find((link) => link.kind === "demo");
      const others = links.filter((link) => link !== primary);
      const access = ACCESS[project.access];
      const media = (project.media || []).filter(
        (item) => item.url && !this.failedUrls.includes(item.url)
      );
      const desktop = media.find((item) => item.device !== "phone");
      const phone = media.find((item) => item.device === "phone");
      const classes = ["card"];
      if (project.featured) classes.push("featured");
      if (desktop || phone) classes.push("has-media");
      return {
        ...project,
        key: project.id || `p${index}`,
        cardClass: classes.join(" "),
        badge: project.featured ? "Featured" : "",
        access: access
          ? { ...access, cssClass: `access ${project.access}` }
          : null,
        hasTryIt: Boolean(project.tryIt),
        tags: (project.tags || []).map((text, i) => ({
          key: `p${index}-t${i}`,
          text
        })),
        primary,
        others,
        hasActions: links.length > 0,
        desktop,
        phone,
        hasMedia: Boolean(desktop || phone),
        mediaClass: desktop ? "media" : "media phone-only"
      };
    });
    // Featured first; Array.sort is stable, so each group keeps the order it was written in.
    return cards.sort((a, b) => Number(!!b.featured) - Number(!!a.featured));
  }

  handleImageError(event) {
    this.failedUrls = [...this.failedUrls, event.target.dataset.url];
  }
}
