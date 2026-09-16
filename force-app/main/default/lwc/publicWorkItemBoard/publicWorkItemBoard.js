import { LightningElement, api, wire } from "lwc";
import getPublicBoardData from "@salesforce/apex/PublicBoardController.getPublicBoardData";

const DEFAULT_COLUMNS = "To Do,In Progress,Done";

/**
 * Read-only board for unauthenticated site visitors.
 *
 * A separate component from workItemBoard rather than a mode on it, because that component
 * statically imports WorkItemBoardController - the class a guest must never reach. An import is
 * not conditional, so a shared component would drag the forbidden class into the guest bundle no
 * matter which branch ran. This one imports PublicBoardController and nothing else.
 *
 * It follows that there is no selection, no detail panel and no status change here: not hidden,
 * absent. The only Apex it can call has no write method.
 */
export default class PublicWorkItemBoard extends LightningElement {
  _columnsRaw = DEFAULT_COLUMNS;

  board;
  viewColumns = [];
  otherCards = [];
  errorMessage;
  isLoading = true;

  /** Ordered, comma separated Status__c values. */
  @api
  get columns() {
    return this._columnsRaw;
  }
  set columns(value) {
    this._columnsRaw =
      value && String(value).trim() ? String(value) : DEFAULT_COLUMNS;
    this.rebuild();
  }

  // No parameters, matching the Apex. There is nothing this component could pass that would
  // widen what comes back.
  @wire(getPublicBoardData)
  wiredBoard(result) {
    if (result.data) {
      this.board = result.data;
      this.errorMessage = undefined;
      this.isLoading = false;
      this.rebuild();
    } else if (result.error) {
      this.board = undefined;
      this.viewColumns = [];
      this.otherCards = [];
      this.errorMessage = "The board is unavailable right now.";
      this.isLoading = false;
    }
  }

  // ---------- state ----------

  get hasError() {
    return !!this.errorMessage;
  }
  get isEmpty() {
    return (
      !this.isLoading &&
      !this.hasError &&
      !!this.board &&
      this.board.itemCount === 0
    );
  }
  get showBoard() {
    return (
      !this.isLoading &&
      !this.hasError &&
      !!this.board &&
      this.board.itemCount > 0
    );
  }
  get hasOther() {
    return this.otherCards.length > 0;
  }
  get headingLabel() {
    return this.board && this.board.projectLabel
      ? this.board.projectLabel
      : "Work items";
  }
  get freshnessLabel() {
    if (!this.board || !this.board.lastSyncedAt) {
      return "";
    }
    return `Last updated ${new Date(this.board.lastSyncedAt).toLocaleDateString()}`;
  }
  get countLabel() {
    const n = this.board ? this.board.itemCount : 0;
    return `${n} ${n === 1 ? "item" : "items"}`;
  }

  // ---------- view model ----------

  get configuredColumns() {
    return this._columnsRaw
      .split(",")
      .map((name) => name.trim())
      .filter((name) => name.length > 0);
  }

  rebuild() {
    if (!this.board || !this.board.items) {
      this.viewColumns = [];
      this.otherCards = [];
      return;
    }

    const cards = this.board.items.map((item) => this.toCard(item));
    const configured = this.configuredColumns;
    const configuredSet = new Set(configured);

    this.viewColumns = configured.map((status) => {
      const inColumn = cards.filter((card) => card.status === status);
      const numbersHere = new Set(inColumn.map((card) => card.recordNumber));
      // Nest only when parent and child share a column. A child elsewhere simply stands on
      // its own - no note, because a note about a record a visitor cannot see is either
      // noise or a leak.
      const tops = inColumn.filter(
        (card) => !card.parentNumber || !numbersHere.has(card.parentNumber)
      );
      tops.forEach((card) => {
        card.children = inColumn.filter(
          (other) => other.parentNumber === card.recordNumber
        );
        card.hasChildren = card.children.length > 0;
      });
      return {
        key: status,
        label: status,
        cards: tops,
        isEmpty: inColumn.length === 0,
        countLabel: `${inColumn.length}`
      };
    });

    // Anything the configured columns do not account for still renders, rather than silently
    // disappearing from a public page.
    this.otherCards = cards.filter((card) => !configuredSet.has(card.status));
  }

  toCard(item) {
    const hasTitle = !!item.title;
    const heading = item.title || item.externalKey || item.recordNumber;
    const ident = item.externalKey
      ? `${item.recordNumber} · ${item.externalKey}`
      : item.recordNumber;
    const isSynced = item.syncStatus === "Synced";
    return {
      recordNumber: item.recordNumber,
      heading,
      headingClass: hasTitle ? "has-title" : "is-fallback",
      identLabel: ident,
      status: item.status,
      // The DTO already sends null for an unmapped type, so the component never has to know
      // the sentinel value.
      type: item.type,
      hasType: !!item.type,
      projectLabel: item.projectLabel,
      hasProjectLabel: !!item.projectLabel,
      syncStatus: item.syncStatus,
      showSyncFlag: !isSynced,
      syncClass:
        item.syncStatus === "Failed"
          ? "sync-flag sync-failed"
          : "sync-flag sync-pending",
      parentNumber: item.parentNumber || null,
      children: [],
      hasChildren: false
    };
  }
}
