import { LightningElement, api } from "lwc";

/**
 * A single card on the public board. Presentational and inert: it renders the view model the
 * board hands it, raises no events, and offers no affordance to act.
 *
 * Separate from workItemCard rather than reused, because that card is clickable - it carries
 * role="button", a tabindex and key handlers for the status change path. Reusing it here would
 * put interactive affordances in front of a visitor who has no write access at all.
 *
 * No base components, for the same reason as the internal board: this one actually runs in LWR.
 */
export default class PublicWorkItemCard extends LightningElement {
  @api card;
}
