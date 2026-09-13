import { LightningElement, api } from "lwc";

/**
 * One board card. Presentational only - it renders the view model the board hands it and makes
 * no decisions of its own, so the same card works on an internal page and, later, a public site.
 *
 * Deliberately no base components. Every lightning-* component is one more thing that can behave
 * differently in an LWR site, and this card is destined for one.
 */
export default class WorkItemCard extends LightningElement {
  @api card;

  handleSelect() {
    this.dispatchEvent(
      new CustomEvent("select", { detail: { id: this.card.id } })
    );
  }

  /** A card is operable by keyboard as well as mouse; role="button" implies both keys. */
  handleKey(event) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      this.handleSelect();
    }
  }
}
