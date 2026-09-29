import { LightningElement, api } from "lwc";

/**
 * A row of links to the owner's other profiles: LinkedIn, GitHub, Trailhead, email. Used by the
 * hero and the footer, so a profile is added in one place and shows in both.
 *
 * A link with no url is left out. A web link opens in a new tab and says so to a screen reader; a
 * mailto: link opens the mail app and does not.
 */
export default class PortfolioLinks extends LightningElement {
  /** [{ id, label, icon, url }] from portfolioContent.PROFILE_LINKS. */
  @api links = [];
  /** "dark" for use on the navy footer; anything else is the light treatment. */
  @api tone = "light";

  get items() {
    return (this.links || [])
      .filter((link) => link.url)
      .map((link) => {
        const external = /^https?:/i.test(link.url);
        return {
          ...link,
          external,
          target: external ? "_blank" : null,
          rel: external ? "noopener noreferrer" : null
        };
      });
  }

  get listClass() {
    return this.tone === "dark" ? "links dark" : "links";
  }
}
