import { LightningElement, api } from "lwc";

/**
 * The close of the page: a heading and a line inviting contact, the email button, the profile
 * links, and the copyright. It is the "Contact" the navigation scrolls to. With no email it shows
 * the heading and the profile links alone.
 */
export default class PortfolioFooter extends LightningElement {
  @api name = "";
  @api heading = "";
  @api text = "";
  /** A mailto: url. Empty hides the button. */
  @api emailUrl = "";
  /** [{ id, label, icon, url }], passed straight to portfolioLinks. */
  @api links = [];

  get hasEmail() {
    return Boolean(this.emailUrl);
  }

  get hasText() {
    return Boolean(this.text);
  }

  /** The email link is the button above them, so it is not repeated among the profiles. */
  get profileLinks() {
    return (this.links || []).filter(
      (link) => !this.hasEmail || link.url !== this.emailUrl
    );
  }

  get copyright() {
    return `© ${new Date().getFullYear()} ${this.name}`;
  }
}
