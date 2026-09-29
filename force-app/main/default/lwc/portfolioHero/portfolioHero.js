import { LightningElement, api } from "lwc";

/**
 * The first screen: the owner's name, what they do, a short introduction, the two things a
 * visitor most often came for (the work and the résumé), and the profile links, beside the
 * profile picture.
 *
 * The picture has three states and none of them leaves a hole in the layout: the photo, the
 * initials when no photo is set, and the initials again if the photo fails to load.
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
  @api resumeUrl = "";
  @api resumeLabel = "Résumé";
  /** [{ id, label, icon, url }], passed straight to portfolioLinks. */
  @api links = [];
  /** True when the page has a Projects section for the first button to go to. */
  @api hasProjects = false;

  photoFailed = false;

  get showPhoto() {
    return Boolean(this.photoUrl) && !this.photoFailed;
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
    this.photoFailed = true;
  }

  handleProjects(event) {
    event.preventDefault();
    this.dispatchEvent(
      new CustomEvent("navigate", { detail: { id: "projects" } })
    );
  }
}
