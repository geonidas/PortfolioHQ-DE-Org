import { LightningElement, api } from "lwc";

/**
 * The first screen: the owner's name, what they do, a short introduction, the two things a
 * visitor most often came for (the work and the résumé), and the profile links, beside the
 * profile picture.
 *
 * The picture falls back in order and never leaves a hole in the layout: the WebP photo, the
 * JPG photo (for browsers without WebP, or if the WebP fails to load), then the initials when
 * no photo is set or every photo fails to load.
 */
export default class PortfolioHero extends LightningElement {
  @api name = "";
  @api initials = "";
  @api headline = "";
  @api intro = "";
  @api location = "";
  @api availability = "";
  /** A full url. The page builds it from the static resource and the file name in the content. */
  @api photoUrl = "";
  /**
   * Optional. A full url to a JPG/PNG copy of the photo. When set, photoUrl is treated as the
   * WebP version and this one is the fallback.
   */
  @api photoFallbackUrl = "";
  @api resumeUrl = "";
  @api resumeLabel = "Résumé";
  /** [{ id, label, icon, url }], passed straight to portfolioLinks. */
  @api links = [];
  /** True when the page has a Projects section for the first button to go to. */
  @api hasProjects = false;

  primaryFailed = false;
  photoFailed = false;

  get showPhoto() {
    return Boolean(this.photoUrl || this.photoFallbackUrl) && !this.photoFailed;
  }

  /** Offer the WebP source only when there is a fallback to drop back to. */
  get showPrimarySource() {
    return Boolean(this.photoUrl && this.photoFallbackUrl) && !this.primaryFailed;
  }

  get imgSrc() {
    return this.photoFallbackUrl || this.photoUrl;
  }

  get photoAlt() {
    return `Portrait of ${this.name}`;
  }

  get hasResume() {
    return Boolean(this.resumeUrl);
  }

  get hasLocation() {
    return Boolean(this.location);
  }

  get hasAvailability() {
    return Boolean(this.availability);
  }

  handlePhotoError() {
    if (this.showPrimarySource) {
      // Drop the WebP source; the browser re-selects and loads the fallback in <img>.
      this.primaryFailed = true;
    } else {
      this.photoFailed = true;
    }
  }

  handleProjects(event) {
    event.preventDefault();
    this.dispatchEvent(
      new CustomEvent("navigate", { detail: { id: "projects" } })
    );
  }
}