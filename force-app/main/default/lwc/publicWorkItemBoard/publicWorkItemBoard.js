import { LightningElement, api, wire } from "lwc";
import getPublicBoardData from "@salesforce/apex/PublicBoardController.getPublicBoardData";

const DEFAULT_COLUMNS = "To Do,In Progress,Done";
const VIEW_TASKS = "tasks";
const VIEW_EPICS = "epics";
const DONE = "Done";

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
  epicCards = [];
  epicColumns = [];
  otherEpics = [];
  errorMessage;
  isLoading = true;

  // Which view is on screen. Display state only - see handleView.
  view = VIEW_TASKS;

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
  // The board as a whole is empty only when neither view has anything. With epics present
  // but no open work, the task view shows its own empty state and the toggle stays reachable.
  get isEmpty() {
    return (
      !this.isLoading &&
      !this.hasError &&
      !!this.board &&
      this.taskCount === 0 &&
      this.epicCount === 0
    );
  }
  get showBoard() {
    return (
      !this.isLoading &&
      !this.hasError &&
      !!this.board &&
      (this.taskCount > 0 || this.epicCount > 0)
    );
  }
  get hasOther() {
    return this.otherCards.length > 0;
  }

  // ---------- view switching ----------

  /**
   * Switches which payload is rendered. Nothing else.
   *
   * Both datasets arrived together in the single cacheable call that loaded the page, so this
   * re-renders from memory and issues no request. It could not issue a narrower one in any
   * case: getPublicBoardData takes no parameters, so there is nothing the client can send that
   * would change what comes back.
   */
  handleView(event) {
    const next = event.currentTarget.dataset.view;
    if (next && next !== this.view) {
      this.view = next;
    }
  }

  get isTaskView() {
    return this.view === VIEW_TASKS;
  }
  get isEpicView() {
    return this.view === VIEW_EPICS;
  }
  // aria-pressed wants the string, not the boolean.
  get taskPressed() {
    return String(this.isTaskView);
  }
  get epicPressed() {
    return String(this.isEpicView);
  }
  get taskToggleClass() {
    return this.isTaskView ? "view-btn is-on" : "view-btn";
  }
  get epicToggleClass() {
    return this.isEpicView ? "view-btn is-on" : "view-btn";
  }

  get epicCount() {
    return this.epicCards.length;
  }
  get hasOtherEpics() {
    return this.otherEpics.length > 0;
  }
  get taskCount() {
    return this.board ? this.board.itemCount : 0;
  }

  // Each view says for itself when it has nothing, because "no epics yet" and "no open work"
  // are different facts and a visitor who sees a blank panel cannot tell which one they hit.
  get isTaskViewEmpty() {
    return this.taskCount === 0;
  }
  get isEpicViewEmpty() {
    return this.epicCount === 0;
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
    if (this.isEpicView) {
      const e = this.epicCount;
      return `${e} ${e === 1 ? "epic" : "epics"}`;
    }
    const n = this.taskCount;
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
    this.rebuildEpics();
    if (!this.board || !this.board.items) {
      this.viewColumns = [];
      this.otherCards = [];
      return;
    }

    const cards = this.board.items.map((item) => this.toCard(item));
    const laid = this.toColumns(cards, (inColumn) => this.nest(inColumn));
    this.viewColumns = laid.columns;
    this.otherCards = laid.other;
  }

  /**
   * Lay a set of cards into the configured status columns, plus whatever the columns do not
   * account for.
   *
   * Shared by both views on purpose. The epic view is not a different layout - it is the same
   * board reading different rows. That is also what leaves room for the Asana work: a second
   * source adds cards to these same columns rather than needing a third view, and the column
   * set stays a single piece of configuration for all of it.
   *
   * `decorate` is how a view adds its own per-column arrangement. The task view uses it to nest
   * children under parents; the epic view has no hierarchy to express and passes nothing.
   */
  toColumns(cards, decorate) {
    const configured = this.configuredColumns;
    const configuredSet = new Set(configured);
    const columns = configured.map((status) => {
      const inColumn = cards.filter((card) => card.status === status);
      return {
        key: status,
        label: status,
        cards: decorate ? decorate(inColumn) : inColumn,
        isEmpty: inColumn.length === 0,
        countLabel: `${inColumn.length}`
      };
    });
    // Anything the configured columns do not account for still renders, rather than silently
    // disappearing from a public page.
    return {
      columns,
      other: cards.filter((card) => !configuredSet.has(card.status))
    };
  }

  /**
   * Nest only when parent and child share a column. A child elsewhere simply stands on its own -
   * no note, because a note about a record a visitor cannot see is either noise or a leak.
   */
  nest(inColumn) {
    const numbersHere = new Set(inColumn.map((card) => card.recordNumber));
    const tops = inColumn.filter(
      (card) => !card.parentNumber || !numbersHere.has(card.parentNumber)
    );
    tops.forEach((card) => {
      card.children = inColumn.filter(
        (other) => other.parentNumber === card.recordNumber
      );
      card.hasChildren = card.children.length > 0;
    });
    return tops;
  }

  /**
   * Lays the epic payload into the same columns as the task view, keyed on each epic's own
   * status.
   *
   * The server still decides which epics exist - every active one, plus at most the three most
   * recently updated completed ones. That cap is not re-implemented here and cannot drift from
   * it; it simply means the Done column is bounded, which is the whole point of capping it.
   */
  rebuildEpics() {
    const epics = (this.board && this.board.epics) || [];
    this.epicCards = epics.map((epic, index) => this.toEpicCard(epic, index));
    const laid = this.toColumns(this.epicCards);
    this.epicColumns = laid.columns.map((col) => ({
      ...col,
      // Per column, because "no completed epics yet" and "nothing in progress" are different
      // facts. A first-run org has completed nothing, and that column has to say so rather
      // than sit blank under its heading.
      emptyKey:
        col.key === DONE
          ? "completed"
          : col.key.toLowerCase().replace(/\s+/g, "-"),
      emptyLabel: col.key === DONE ? "No completed epics yet" : "No epics here"
    }));
    this.otherEpics = laid.other;
  }

  toEpicCard(epic, index) {
    const total = epic.totalChildren || 0;
    const done = epic.completedChildren || 0;
    const percent = total > 0 ? Math.round((done / total) * 100) : 0;
    const isComplete = epic.status === DONE;
    return {
      // The DTO carries no identifier at all, by design - no id, no auto number, no key.
      // The list is rebuilt whole from each payload, so a positional key is stable for
      // exactly as long as it needs to be.
      key: `epic-${index}`,
      // No fallback to an external key or record number, because neither is in the epic
      // payload. An untitled epic is labelled here rather than published differently.
      heading: epic.title || "Untitled epic",
      headingClass: epic.title ? "has-title" : "is-fallback",
      status: epic.status,
      statusClass: isComplete ? "status status-done" : "status",
      isComplete,
      hasChildren: total > 0,
      // "0 of 0" reads as broken. An epic with nothing under it says so in words.
      progressLabel:
        total > 0 ? `${done} of ${total} done` : "No child items yet",
      barStyle: `width: ${percent}%`
    };
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
