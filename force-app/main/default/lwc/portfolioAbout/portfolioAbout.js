import { LightningElement, api } from "lwc";

/**
 * A short account of the owner in their own voice, after the work rather than before it. It is
 * deliberately only prose: history, skills and certifications are on the résumé and LinkedIn, and
 * the page does not keep a second copy of them to go stale.
 */
export default class PortfolioAbout extends LightningElement {
  /** An array of paragraphs. */
  @api summary = [];

  get paragraphs() {
    return (this.summary || []).map((text, index) => ({
      key: `p${index}`,
      text
    }));
  }
}
