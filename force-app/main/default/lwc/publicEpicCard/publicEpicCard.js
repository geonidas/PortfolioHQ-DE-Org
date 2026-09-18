import { LightningElement, api } from "lwc";

/**
 * A single epic card on the public board. Presentational and inert, exactly like
 * publicWorkItemCard: it renders the view model the board hands it, raises no events, and offers
 * no affordance to act. No role, no tabindex, no handlers.
 *
 * The progress bar is decorative and marked aria-hidden. The same information is in the text
 * label beside it, so a screen reader gets the count rather than a bar it cannot measure.
 *
 * No base components, for the same reason as the rest of the public board: this one runs in LWR.
 */
export default class PublicEpicCard extends LightningElement {
  @api epic;
}
