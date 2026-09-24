import { LightningElement, api } from "lwc";

/**
 * One epic card, on either board. Presentational and inert: it renders the view model the board
 * hands it - see boardModel.epicModel - raises no events and offers nothing to act on.
 *
 * The progress bar is decorative and hidden from screen readers; the count beside it says the
 * same thing in words.
 */
export default class BoardEpicCard extends LightningElement {
  @api epic;
}
