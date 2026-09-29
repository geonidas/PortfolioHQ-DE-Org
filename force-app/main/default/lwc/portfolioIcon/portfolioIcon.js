import { LightningElement, api } from "lwc";

/*
 * Inline SVG on a 24 x 24 grid, so the page makes no request for an icon and a strict CSP has
 * nothing to allow. Brand marks are filled glyphs and the rest are outlines; the GitHub path is
 * from Simple Icons (CC0). LinkedIn and Trailhead are drawn here as plain "in" and mountain
 * shapes, not the companies' own artwork.
 */
const ICONS = {
  github: {
    filled: true,
    d: "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"
  },
  linkedin: {
    filled: true,
    evenodd: true,
    d: "M3 0h18a3 3 0 0 1 3 3v18a3 3 0 0 1-3 3H3a3 3 0 0 1-3-3V3a3 3 0 0 1 3-3zM4.5 9.5h3.5v10H4.5zM6.25 4.1a2 2 0 1 0 0 4 2 2 0 0 0 0-4zM10 9.5h3.35v1.4c.5-.9 1.6-1.65 3.25-1.65 3.1 0 3.9 2 3.9 4.7v5.55H17v-5c0-1.2-.05-2.5-1.55-2.5s-1.75 1.2-1.75 2.45v5.05H10z"
  },
  trailhead: {
    d: "M2.5 19.5 9 8l3.5 6 2.2-3.6 6.8 9.1zM7.4 11.6 9 14.4l1.4-2.4"
  },
  mail: {
    d: "M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM3.5 6.5 12 13l8.5-6.5"
  },
  external: {
    d: "M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"
  },
  download: { d: "M12 4v11M7.5 10.5 12 15l4.5-4.5M4 19h16" },
  pin: {
    d: "M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11zM12 12.2a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4z"
  },
  menu: { d: "M4 7h16M4 12h16M4 17h16" },
  close: { d: "M6 6l12 12M18 6 6 18" },
  arrow: { d: "M5 12h14M13 6l6 6-6 6" },
  code: { d: "M8 8l-4 4 4 4M16 8l4 4-4 4M13.5 5l-3 14" },
  eye: {
    d: "M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12zM12 14.8a2.8 2.8 0 1 0 0-5.6 2.8 2.8 0 0 0 0 5.6z"
  },
  play: {
    d: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM10.3 8.7v6.6l5.4-3.3z"
  },
  cursor: { d: "M5.5 3.5 19 10l-6 1.8-2 6.7z" },
  image: {
    d: "M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM3 16l5-5 4 4 3-3 6 6"
  }
};

/**
 * One icon by name. It is decorative: whatever carries it (a link, a button) supplies the
 * accessible name, so the svg is hidden from assistive technology. Sized in em, so it follows the
 * font size of the element that holds it; colored with currentColor.
 */
export default class PortfolioIcon extends LightningElement {
  @api name;

  get icon() {
    return ICONS[this.name] || ICONS.arrow;
  }

  get path() {
    return this.icon.d;
  }

  get shapeClass() {
    return this.icon.filled ? "glyph" : "outline";
  }

  get fillRule() {
    return this.icon.evenodd ? "evenodd" : "nonzero";
  }
}
