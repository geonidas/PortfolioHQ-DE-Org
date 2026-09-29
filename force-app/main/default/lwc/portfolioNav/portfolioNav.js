import { LightningElement, api } from "lwc";

/**
 * The bar across the top: the owner's name, a link to each section that has content, and the
 * résumé. It raises navigate with { id } and does not scroll anything itself; the page owns the
 * scrolling, so the same code answers this bar and the hero's button.
 *
 * Below the tablet width the links fold into a menu. The button that opens it says whether it is
 * open (aria-expanded), and Escape closes it and gives focus back to the button.
 */
export default class PortfolioNav extends LightningElement {
  @api name = "";
  @api initials = "";
  /** [{ id, label }] in page order. Only sections that exist. */
  @api links = [];
  /** The id of the section in view, or "" while the hero is. */
  @api active = "";
  @api resumeUrl = "";
  @api resumeLabel = "Résumé";

  menuOpen = false;

  get items() {
    return (this.links || []).map((link) => ({
      ...link,
      href: `#${link.id}`,
      current: link.id === this.active ? "true" : null
    }));
  }

  get hasResume() {
    return Boolean(this.resumeUrl);
  }

  get linksClass() {
    return this.menuOpen ? "links open" : "links";
  }

  get menuExpanded() {
    return String(this.menuOpen);
  }

  get menuLabel() {
    return this.menuOpen ? "Close menu" : "Open menu";
  }

  get menuIcon() {
    return this.menuOpen ? "close" : "menu";
  }

  handleBrand(event) {
    event.preventDefault();
    this.navigate("top");
  }

  handleLink(event) {
    event.preventDefault();
    this.navigate(event.currentTarget.dataset.id);
  }

  navigate(id) {
    this.menuOpen = false;
    this.dispatchEvent(new CustomEvent("navigate", { detail: { id } }));
  }

  toggleMenu() {
    this.menuOpen = !this.menuOpen;
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.menuOpen) {
      this.menuOpen = false;
      this.template.querySelector("[data-menu-button]").focus();
    }
  }
}
