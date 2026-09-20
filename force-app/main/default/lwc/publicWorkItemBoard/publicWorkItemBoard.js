import { LightningElement, api, wire } from "lwc";
import getPublicBoardData from "@salesforce/apex/PublicBoardController.getPublicBoardData";
import {
  DEFAULT_COLUMNS,
  columnsFrom,
  layoutColumns,
  nestByParent
} from "c/boardLayout";

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
  passThroughCards = [];
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

  // Everything the epic view shows: the epics, plus the cards the toggle leaves alone. A board
  // with no epics but some flat work is not an empty epic view.
  get epicCount() {
    return this.epicCards.length + this.passThroughCards.length;
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
    return columnsFrom(this._columnsRaw);
  }

  rebuild() {
    this.rebuildEpics();
    if (!this.board || !this.board.items) {
      this.viewColumns = [];
      this.otherCards = [];
      return;
    }

    const cards = this.board.items.map((item) => this.toCard(item));
    // Nest only when parent and child share a column. A child elsewhere simply stands on its
    // own - no note, because a note about a record a visitor cannot see is either noise or a
    // leak. Keyed on auto numbers, since this board publishes no ids at all.
    const laid = layoutColumns(
      cards,
      this.configuredColumns,
      (inColumn) =>
        nestByParent(
          inColumn,
          (card) => card.recordNumber,
          (card) => card.parentNumber
        ).tops
    );
    this.viewColumns = laid.columns;
    this.otherCards = laid.other;
  }

  /**
   * Lays the epic view into the same columns as the task view.
   *
   * Two kinds of card share those columns, and which kind a card is was decided by the server:
   * every card carries condensesIntoEpic, and the epic toggle is a transform that applies only
   * to the ones where it is true.
   *
   * - A card that condenses is replaced by the epic it belongs to. That is the whole point of
   *   the view: once a project is finished the individual tasks matter less than the epic did.
   * - A card that does not condense passes through untouched, into the column its own status
   *   names. It is not an epic and it is not an orphan - it is flat, and there is nothing to
   *   roll it up into.
   *
   * No branch on a vendor name anywhere, because no vendor name is in the payload. The server
   * asks BoardSourceRules and publishes the answer as a boolean.
   *
   * The server still decides which epics exist - every active one, plus at most the three most
   * recently updated completed ones. That cap is not re-implemented here and cannot drift from
   * it; it simply means the Done column is bounded, which is the whole point of capping it.
   */
  rebuildEpics() {
    const epics = (this.board && this.board.epics) || [];
    this.epicCards = epics.map((epic, index) => this.toEpicCard(epic, index));

    // Cards the toggle does not transform, shown identically in both views.
    this.passThroughCards = ((this.board && this.board.items) || [])
      .filter((item) => !item.condensesIntoEpic)
      .map((item) => ({
        ...this.toCard(item),
        isEpic: false,
        // The epic columns key on `key`, because epic cards carry no identifier of any kind.
        // A pass-through card has an auto number, so it uses that rather than a position -
        // stable across a re-render in a way an index is not.
        key: `item-${item.recordNumber}`
      }));

    const laid = layoutColumns(
      [...this.epicCards, ...this.passThroughCards],
      this.configuredColumns
    );
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
      // Tells the template which component to render, now that the epic columns hold both.
      isEpic: true,
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
    // The DTO has always carried lastSyncedAt per card; until the refactor pass after build 06
    // nothing rendered it, so a visitor could not tell a fresh card from a stale one.
    const lastSyncedLabel = item.lastSyncedAt
      ? `Updated ${new Date(item.lastSyncedAt).toLocaleDateString()}`
      : null;
    return {
      recordNumber: item.recordNumber,
      lastSyncedLabel,
      hasLastSynced: !!lastSyncedLabel,
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
      hasChildren: false,
      // Decided by the server, from BoardSourceRules. The client never sees a vendor name.
      condensesIntoEpic: !!item.condensesIntoEpic,
      isEpic: false
    };
  }
}
