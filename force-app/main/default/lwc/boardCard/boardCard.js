import { LightningElement, api } from "lwc";

/**
 * One card, on either board. It renders the view model the board hands it - see
 * boardModel.cardModel - and decides nothing about the data.
 *
 * What it can do is a capability the board grants, not a mode it infers. `selectable` puts a
 * button in the card's heading that raises select; the internal board passes it and the public
 * board does not, so a public card has no control in it at all. Build 08 step 7 turns that
 * button into the card's disclosure and adds the rest of the capabilities there.
 *
 * No base components: this card runs in an LWR site, where every lightning-* component is one
 * more thing that can behave differently.
 */
export default class BoardCard extends LightningElement {
  @api card;
  @api selectable = false;

  handleSelect() {
    this.dispatchEvent(
      new CustomEvent("select", { detail: { key: this.card.key } })
    );
  }
}
