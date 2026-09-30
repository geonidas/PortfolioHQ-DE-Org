import { LightningElement } from "lwc";
import ASSETS from "@salesforce/resourceUrl/portfolio_assets";
import {
  PROFILE,
  RESUME,
  PROFILE_LINKS,
  PROJECTS_INTRO,
  PROJECTS,
  ABOUT,
  CONTACT
} from "c/portfolioContent";

/**
 * The whole portfolio, placed on a site page as one component. It reads portfolioContent, decides
 * which sections have something to show, and hands each its own slice; the sections import
 * nothing, so one can be copied, changed or dropped without touching the others. It is also the
 * only place that turns a file name in the content into an address in the static resource.
 *
 * The order is the argument of the page: the introduction, then the work, then a short account of
 * the person, then how to reach them.
 *
 * It also owns the scrolling. The top bar and the hero's button both raise navigate, and the one
 * handler here answers both. A thin band across the middle of the screen is watched, and the
 * section that crosses it is the one the bar marks.
 */
export default class PortfolioPage extends LightningElement {
  activeId = "";

  observer;

  profile = PROFILE;
  resume = RESUME;
  links = PROFILE_LINKS;
  projectsIntro = PROJECTS_INTRO;
  about = ABOUT;
  contact = CONTACT;

  get initials() {
    return (PROFILE.name || "")
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((word) => word.charAt(0).toUpperCase())
      .join("");
  }

  get photoUrl() {
    return this.assetUrl(PROFILE.photo);
  }

  /** The projects with each media file resolved to its address. */
  get projects() {
    return PROJECTS.map((project) => ({
      ...project,
      media: (project.media || []).map(({ file, ...rest }) => ({
        ...rest,
        url: this.assetUrl(file)
      }))
    }));
  }

  get emailUrl() {
    const email = PROFILE_LINKS.find((link) => link.id === "email");
    return email ? email.url : "";
  }

  get showProjects() {
    return PROJECTS.length > 0;
  }

  get showAbout() {
    return (ABOUT.summary || []).length > 0;
  }

  /** The navigation: one entry per section that is on the page, in page order. */
  get sections() {
    return [
      { id: "projects", label: "Projects", show: this.showProjects },
      { id: "about", label: "About", show: this.showAbout },
      { id: "contact", label: "Contact", show: true }
    ]
      .filter((section) => section.show)
      .map(({ id, label }) => ({ id, label }));
  }

  assetUrl(file) {
    return file ? `${ASSETS}/${file}` : "";
  }

  renderedCallback() {
    if (this.observer || typeof IntersectionObserver === "undefined") {
      return;
    }
    this.observer = new IntersectionObserver(
      (entries) => {
        const entering = entries.filter((entry) => entry.isIntersecting);
        if (entering.length) {
          this.activeId = entering[entering.length - 1].target.dataset.section;
        } else if (window.scrollY < 80) {
          this.activeId = "";
        }
      },
      { rootMargin: "-45% 0px -50% 0px" }
    );
    this.template
      .querySelectorAll("[data-section]")
      .forEach((section) => this.observer.observe(section));
  }

  disconnectedCallback() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = undefined;
    }
  }

  handleNavigate(event) {
    const id = event.detail.id;
    const smooth = !(
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
    const behavior = smooth ? "smooth" : "auto";
    if (id === "top") {
      window.scrollTo({ top: 0, behavior });
      return;
    }
    const target = this.template.querySelector(`[data-section="${id}"]`);
    if (target) {
      target.scrollIntoView({ behavior, block: "start" });
    }
  }
}
