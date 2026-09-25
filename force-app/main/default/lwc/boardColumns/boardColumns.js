import { LightningElement, api } from "lwc";
import {
  PORTRAIT_QUERY,
  REDUCED_MOTION_QUERY,
  PORTRAIT_START_COLUMN
} from "c/boardLayout";

/** How long the track must be still before a scroll counts as having landed on a column. */
const SETTLE_MS = 120;

/**
 * The board's columns, laid out for the window they are in. Shared by both boards.
 *
 * The board renders its own columns - with its own cards, drop targets and abilities - into this
 * component's slot, each marked data-board-column. This component only arranges them:
 *
 * - Landscape or wider: side by side, as a grid.
 * - Portrait, (orientation: portrait) and (max-width: 700px): one column at a time in a track
 *   that snaps each column to the centre and swipes natively. Two round arrow buttons step to
 *   the neighbouring column and are named for it ("Show Done column"); each is absent at its
 *   end. A position line says which column is showing and where it sits ("In Progress, 2 of 3")
 *   and is a polite live region, so a screen reader hears where a swipe or an arrow landed.
 *   Opens on In Progress where the board has that column.
 *
 * With reduced motion asked for, an arrow jumps instead of scrolling smoothly.
 *
 * Imports nothing but boardLayout's constants, like every module both boards share.
 */
export default class BoardColumns extends LightningElement {
  /** The columns in order, as the board lays them out: [{ key, label }]. */
  @api
  get columns() {
    return this._columns;
  }
  set columns(value) {
    this._columns = value || [];
    // Fewer columns than before - a board reconfigured - keeps the position inside the board.
    if (this.currentIndex > this._columns.length - 1) {
      this.currentIndex = Math.max(this._columns.length - 1, 0);
    }
  }
  /** The column the portrait layout opens on. Defaults to In Progress. */
  @api startKey = PORTRAIT_START_COLUMN;

  isPortrait = false;
  currentIndex = 0;
  _columns = [];
  _media = [];
  _onMediaChange;
  _reducedMotion;
  _positioned = false;
  _settleTimer;
  _focusArrow;

  connectedCallback() {
    if (typeof window.matchMedia !== "function") {
      return;
    }
    const portrait = window.matchMedia(PORTRAIT_QUERY);
    this._reducedMotion = window.matchMedia(REDUCED_MOTION_QUERY);
    this._media = [portrait];
    this._onMediaChange = () => this.updateLayout();
    portrait.addEventListener("change", this._onMediaChange);
    this.updateLayout();
  }

  disconnectedCallback() {
    this._media.forEach((query) =>
      query.removeEventListener("change", this._onMediaChange)
    );
    this._media = [];
    clearTimeout(this._settleTimer);
  }

  renderedCallback() {
    if (this.isPortrait && !this._positioned && this.columnElements().length) {
      // Opening, or turning into portrait: go straight to the start column, without motion.
      this._positioned = true;
      this.currentIndex = this.startIndex;
      this.scrollToIndex(this.currentIndex, false);
    }
    if (this._focusArrow) {
      const arrow = this.template.querySelector(
        `[data-arrow="${this._focusArrow}"]`
      );
      this._focusArrow = undefined;
      if (arrow) {
        arrow.focus();
      }
    }
  }

  updateLayout() {
    const portrait = this._media[0];
    const now = !!portrait && portrait.matches;
    if (now !== this.isPortrait) {
      this.isPortrait = now;
      this._positioned = false;
    }
  }

  // ---------- state ----------

  get count() {
    return (this.columns || []).length;
  }
  get startIndex() {
    const index = (this.columns || []).findIndex(
      (column) => column.key === this.startKey
    );
    return index >= 0 ? index : 0;
  }
  get current() {
    return (this.columns || [])[this.currentIndex];
  }
  get hasPrevious() {
    return this.isPortrait && this.currentIndex > 0;
  }
  get hasNext() {
    return this.isPortrait && this.currentIndex < this.count - 1;
  }
  get previousLabel() {
    const column = this.columns[this.currentIndex - 1];
    return column ? `Show ${column.label} column` : "";
  }
  get nextLabel() {
    const column = this.columns[this.currentIndex + 1];
    return column ? `Show ${column.label} column` : "";
  }
  get positionLabel() {
    return this.current
      ? `${this.current.label} · ${this.currentIndex + 1} of ${this.count}`
      : "";
  }
  get positionSpoken() {
    return this.current
      ? `${this.current.label}, ${this.currentIndex + 1} of ${this.count}`
      : "";
  }
  get showPosition() {
    return this.isPortrait && this.count > 1;
  }
  get frameClass() {
    return this.isPortrait ? "frame is-portrait" : "frame";
  }

  // ---------- moving ----------

  /** The board's columns, in order. They are the board's elements, slotted in here. */
  columnElements() {
    return Array.from(this.querySelectorAll("[data-board-column]"));
  }

  handlePrevious() {
    this.step(-1);
  }

  handleNext() {
    this.step(1);
  }

  step(by) {
    const target = Math.min(
      Math.max(this.currentIndex + by, 0),
      this.count - 1
    );
    if (target === this.currentIndex) {
      return;
    }
    this.currentIndex = target;
    this.scrollToIndex(target, true);
    // An arrow at its end disappears. Focus goes to the one that is left rather than to the page.
    if (by > 0 && !this.hasNext) {
      this._focusArrow = "previous";
    } else if (by < 0 && !this.hasPrevious) {
      this._focusArrow = "next";
    }
  }

  /** Centres a column in the track. Smoothly, unless motion is reduced or this is the first place. */
  scrollToIndex(index, animate) {
    const track = this.template.querySelector("[data-track]");
    const column = this.columnElements()[index];
    if (!track || !column || typeof track.scrollBy !== "function") {
      return;
    }
    const trackBox = track.getBoundingClientRect();
    const columnBox = column.getBoundingClientRect();
    const delta =
      columnBox.left +
      columnBox.width / 2 -
      (trackBox.left + trackBox.width / 2);
    const reduced = !!this._reducedMotion && this._reducedMotion.matches;
    track.scrollBy({
      left: delta,
      behavior: animate && !reduced ? "smooth" : "auto"
    });
  }

  /**
   * A swipe, or focus moving into another column: once the track is still, the column nearest
   * its centre is the current one. Waiting for it to settle keeps the position line - a live
   * region - from announcing every column a smooth scroll passes.
   */
  handleScroll() {
    if (!this.isPortrait) {
      return;
    }
    clearTimeout(this._settleTimer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._settleTimer = setTimeout(() => this.settle(), SETTLE_MS);
  }

  settle() {
    const track = this.template.querySelector("[data-track]");
    const columns = this.columnElements();
    if (!track || !columns.length) {
      return;
    }
    const trackBox = track.getBoundingClientRect();
    const centre = trackBox.left + trackBox.width / 2;
    let nearest = 0;
    let best = Infinity;
    columns.forEach((column, index) => {
      const box = column.getBoundingClientRect();
      const distance = Math.abs(box.left + box.width / 2 - centre);
      if (distance < best) {
        best = distance;
        nearest = index;
      }
    });
    this.currentIndex = nearest;
  }
}
