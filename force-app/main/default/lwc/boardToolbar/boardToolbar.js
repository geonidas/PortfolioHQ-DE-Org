import { LightningElement, api } from "lwc";
import {
  VIEW_OPTIONS,
  ALL_SOURCES,
  SORT_OPTIONS,
  DEFAULT_SORT,
  selectOptions
} from "c/boardModel";

/**
 * The View and Source filters and the Sort, shared by both boards.
 *
 * Display state only. It raises viewchange, sourcechange and sortchange, and the board re-renders
 * what it already holds; nothing here reaches the server, and on the public board nothing could -
 * the one Apex method there takes no parameters.
 *
 * Native selects with visible labels rather than a custom listbox: they are keyboard operable,
 * announced correctly and usable on a phone without any code of ours.
 */
export default class BoardToolbar extends LightningElement {
  @api view;
  @api source = ALL_SOURCES;
  /** [{ value, label }], "All sources" first. See boardModel.sourceOptions. */
  @api sourceOptions = [];
  /** Build 09: boardModel.SORT_DUE or SORT_PRIORITY. */
  @api sort = DEFAULT_SORT;

  get viewItems() {
    return selectOptions(VIEW_OPTIONS, this.view);
  }

  get sourceItems() {
    return selectOptions(this.sourceOptions || [], this.source);
  }

  get sortItems() {
    return selectOptions(SORT_OPTIONS, this.sort);
  }

  handleView(event) {
    this.dispatchEvent(
      new CustomEvent("viewchange", { detail: { value: event.target.value } })
    );
  }

  handleSource(event) {
    this.dispatchEvent(
      new CustomEvent("sourcechange", { detail: { value: event.target.value } })
    );
  }

  handleSort(event) {
    this.dispatchEvent(
      new CustomEvent("sortchange", { detail: { value: event.target.value } })
    );
  }
}
