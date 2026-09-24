import { LightningElement, api, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import getPublicBoardData from "@salesforce/apex/PublicBoardController.getPublicBoardData";
import {
  DEFAULT_COLUMNS,
  columnsFrom,
  layoutColumns,
  nestByParent
} from "c/boardLayout";
import {
  VIEW_TASKS,
  VIEW_EPICS,
  ALL_SOURCES,
  cardModel,
  epicModel,
  sourceOptions,
  bySource,
  keptSource,
  formatInstant,
  countLabel,
  epicViewCountLabel
} from "c/boardModel";

const DONE = "Done";

/** How often a visible, active page re-reads the board. */
export const POLL_MS = 30000;
/**
 * How long without a visitor doing anything before polling stops and the page says Paused.
 * The site's Developer Edition allowance is ten minutes of server time a day; a tab left open
 * and unattended would otherwise spend it all by itself. Build 08 step 1 decision.
 */
export const IDLE_MS = 300000;
/** What counts as a visitor still being there. Each only records a timestamp. */
const ACTIVITY_EVENTS = [
  "pointerdown",
  "pointermove",
  "keydown",
  "wheel",
  "scroll",
  "touchstart"
];

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
  taskCards = [];
  epicCards = [];
  passThroughCards = [];
  epicColumns = [];
  otherEpics = [];
  errorMessage;
  isLoading = true;

  // What is on screen: which view, which source, and which card is open. Display state only -
  // see handleViewChange.
  view = VIEW_TASKS;
  source = ALL_SOURCES;
  sourceChoices = [];
  expandedKey = null;

  /**
   * A line under the title, set in Experience Builder and empty by default. Page copy, so it
   * lives with the page rather than in the component or the payload.
   */
  @api subtitle;

  // Staying current. LWR sites do not support lightning/empApi, so this board re-reads instead
  // of subscribing: every POLL_MS while the page is visible and the visitor has done something
  // in the last IDLE_MS, and on demand from the Refresh button. Each read is the same call the
  // page loaded with - no parameters, one SOQL query - so polling widens nothing.
  wiredResult;
  lastCheckedAt;
  isPaused = false;
  _lastActivity = 0;
  _pollTimer;
  _onActivity;
  _onVisibility;

  connectedCallback() {
    this._lastActivity = Date.now();
    this._onActivity = () => this.noteActivity();
    this._onVisibility = () => this.handleVisibility();
    ACTIVITY_EVENTS.forEach((name) =>
      window.addEventListener(name, this._onActivity, { passive: true })
    );
    document.addEventListener("visibilitychange", this._onVisibility);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._pollTimer = setInterval(() => this.tick(), POLL_MS);
  }

  disconnectedCallback() {
    clearInterval(this._pollTimer);
    this._pollTimer = undefined;
    ACTIVITY_EVENTS.forEach((name) =>
      window.removeEventListener(name, this._onActivity)
    );
    document.removeEventListener("visibilitychange", this._onVisibility);
  }

  /** One polling beat: re-read only when somebody could be looking. */
  tick() {
    if (document.visibilityState !== "visible" || this.isPaused) {
      return;
    }
    if (Date.now() - this._lastActivity >= IDLE_MS) {
      this.isPaused = true;
      return;
    }
    this.refresh();
  }

  noteActivity() {
    this._lastActivity = Date.now();
    if (this.isPaused) {
      this.isPaused = false;
      this.refresh();
    }
  }

  /** Coming back to the tab counts as activity, and the board catches up at once. */
  handleVisibility() {
    if (document.visibilityState !== "visible") {
      return;
    }
    const wasPaused = this.isPaused;
    this.noteActivity();
    if (!wasPaused) {
      this.refresh();
    }
  }

  handleRefresh() {
    this._lastActivity = Date.now();
    this.isPaused = false;
    this.refresh();
  }

  refresh() {
    if (!this.wiredResult) {
      return;
    }
    refreshApex(this.wiredResult).then(() => {
      this.lastCheckedAt = new Date();
    });
  }

  /** When this page last asked, not when the data last changed - that is the freshness line. */
  get checkedLabel() {
    if (this.isPaused) {
      return "Paused";
    }
    if (!this.lastCheckedAt) {
      return "";
    }
    return `Checked ${this.lastCheckedAt.toLocaleTimeString([], {
      hour: "numeric",
      minute: "2-digit"
    })}`;
  }

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
    this.wiredResult = result;
    if (result.data) {
      this.board = result.data;
      this.errorMessage = undefined;
      this.isLoading = false;
      this.lastCheckedAt = new Date();
      this.rebuild();
    } else if (result.error) {
      this.board = undefined;
      this.rebuild();
      this.errorMessage = "The board is unavailable right now.";
      this.isLoading = false;
    }
  }

  get hasSubtitle() {
    return !!(this.subtitle && String(this.subtitle).trim());
  }

  // ---------- state ----------

  get hasError() {
    return !!this.errorMessage;
  }
  // The board as a whole is empty only when the payload has nothing for either view. Judged on
  // the payload, not on what the filters leave: a filter that empties a view shows that view's
  // own empty state, and the toolbar stays on screen to undo it.
  get isEmpty() {
    return (
      !this.isLoading &&
      !this.hasError &&
      !!this.board &&
      (this.board.items || []).length === 0 &&
      (this.board.epics || []).length === 0
    );
  }
  get hasOther() {
    return this.otherCards.length > 0;
  }

  // ---------- filters ----------

  /**
   * Switches which view is rendered. Nothing else.
   *
   * Both datasets arrived together in the single cacheable call that loaded the page, so this
   * re-renders from memory and issues no request. It could not issue a narrower one in any
   * case: getPublicBoardData takes no parameters, so there is nothing the client can send that
   * would change what comes back. The same is true of the Source filter below.
   */
  handleViewChange(event) {
    const next = event.detail.value;
    if (next === VIEW_TASKS || next === VIEW_EPICS) {
      this.view = next;
    }
  }

  handleSourceChange(event) {
    this.source = event.detail.value || ALL_SOURCES;
    this.rebuild();
  }

  /**
   * Opens a card in place, one at a time. The open card shows what the payload already carries
   * - the whole title, dates in full, the public parent and the project - and nothing more:
   * this board passes its cards no abilities, so an open card has nothing to act with.
   */
  handleToggle(event) {
    const key = event.detail.key;
    this.expandedKey = this.expandedKey === key ? null : key;
  }

  get isTaskView() {
    return this.view === VIEW_TASKS;
  }
  get isEpicView() {
    return this.view === VIEW_EPICS;
  }
  get isFiltered() {
    return this.source !== ALL_SOURCES;
  }
  get filteredEmptyTitle() {
    return `Nothing from ${this.source} here.`;
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
    return this.taskCards.length;
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
  /** When the data last changed, as opposed to checkedLabel: when this page last asked. */
  get freshnessLabel() {
    const when = this.board && formatInstant(this.board.lastSyncedAt);
    return when ? `Updated ${when}` : "";
  }
  // What is on screen, after the filters - not what the payload holds.
  get countLabel() {
    return this.isEpicView
      ? epicViewCountLabel(this.epicCards.length, this.passThroughCards.length)
      : countLabel(this.taskCount, "item", "items");
  }

  // ---------- view model ----------

  get configuredColumns() {
    return columnsFrom(this._columnsRaw);
  }

  /**
   * Both views' layouts, from the payload through the Source filter. The filter runs first, so
   * the epic view's pass-through cards and the counts all agree with it.
   */
  rebuild() {
    const items = (this.board && this.board.items) || [];
    const epics = (this.board && this.board.epics) || [];
    this.sourceChoices = sourceOptions(items, epics);
    this.source = keptSource(this.source, this.sourceChoices);
    const shownItems = bySource(items, this.source);

    this.rebuildEpics(bySource(epics, this.source), shownItems);

    const cards = shownItems.map((item) => this.toCard(item));
    this.taskCards = cards;
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
  rebuildEpics(epics, items) {
    // The DTO carries no identifier at all, by design - no id, no auto number, no key. The list
    // is rebuilt whole from each payload, so a positional key is stable for exactly as long as
    // it needs to be.
    this.epicCards = epics.map((epic, index) =>
      epicModel(epic, { key: `epic-${index}` })
    );

    // Cards the view does not transform, shown identically in both views. A pass-through card
    // has an auto number, so it keys on that rather than a position.
    this.passThroughCards = items
      .filter((item) => !item.condensesIntoEpic)
      .map((item) => this.toCard(item, `item-${item.recordNumber}`));

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

  /**
   * The parent is named by auto number, and only when it is itself public: the payload leaves
   * parentNumber empty otherwise, and the card then says nothing about a parent at all. The
   * board nests on it too.
   */
  toCard(item, key) {
    return Object.assign(cardModel(item, { key }), {
      parentNumber: item.parentNumber || null,
      parentLine: item.parentNumber || null
    });
  }
}
