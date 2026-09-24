import { LightningElement, api, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import { subscribe, unsubscribe, onError } from "lightning/empApi";
import getBoardData from "@salesforce/apex/WorkItemBoardController.getBoardData";
import changeStatus from "@salesforce/apex/WorkItemBoardController.changeStatus";
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
  countLabel,
  epicViewCountLabel
} from "c/boardModel";

const DONE = "Done";

/** Change Data Capture for Work_Item__c, enabled by its PlatformEventChannelMember. */
export const CHANGE_CHANNEL = "/data/Work_Item__ChangeEvent";
/**
 * How long to wait after a change event before refreshing. A single save produces several events
 * in quick succession - the edit, then the sync's own write-back a second or two later - and one
 * refresh after they settle is enough for all of them.
 */
export const REFRESH_DEBOUNCE_MS = 1500;

/**
 * Work item board.
 *
 * Columns come from a configuration string, never from the markup or from a constant in the
 * rendering path. Adding a status is then editing a property on the page, not a deployment -
 * which matters because the Jira board here offers no In Review, so a hardcoded column for it
 * would sit empty forever.
 *
 * Nothing the controller returns is dropped. A record whose status is not one of the configured
 * columns still appears, in a region below the board, rather than vanishing - the same principle
 * build 03 applied when it chose to surface unmapped statuses instead of hiding them.
 */
export default class WorkItemBoard extends LightningElement {
  _projectId = null;
  _columnsRaw = DEFAULT_COLUMNS;

  boardResult;
  board;
  viewColumns = [];
  outsideCards = [];
  epicColumns = [];
  outsideEpics = [];
  epicEntryCount = 0;
  epicCount = 0;
  errorMessage;
  isLoading = true;

  // What is on screen. Display state only: both views and every source are in the one payload.
  view = VIEW_TASKS;
  source = ALL_SOURCES;
  sourceChoices = [];

  allCards = [];
  selectedId = null;
  isSaving = false;
  actionMessage;
  actionError;

  // Live updates. The subscription is the container's alone: the shared components never import
  // lightning/empApi, which LWR sites do not support, and the public board polls instead.
  isLive = false;
  _subscription;
  _refreshTimer;
  _connected = false;

  connectedCallback() {
    this._connected = true;
    onError((error) => {
      // The stream dropped - a network blip or an expired session. Say so rather than
      // implying the board is still live; a page reload re-subscribes.
      this.isLive = false;
      console.warn("Work item change stream error", JSON.stringify(error));
    });
    subscribe(CHANGE_CHANNEL, -1, () => this.scheduleRefresh())
      .then((subscription) => {
        if (!this._connected) {
          // Disconnected while the handshake was in flight: do not leave a subscription behind.
          unsubscribe(subscription);
          return;
        }
        this._subscription = subscription;
        this.isLive = true;
      })
      .catch(() => {
        this.isLive = false;
      });
  }

  disconnectedCallback() {
    this._connected = false;
    clearTimeout(this._refreshTimer);
    this._refreshTimer = undefined;
    if (this._subscription) {
      unsubscribe(this._subscription);
      this._subscription = undefined;
    }
    this.isLive = false;
  }

  /**
   * A change arrived: refresh once the burst has settled. Nothing is read from the event itself
   * - it only says "something changed" - so what renders always comes from the controller, in
   * the running user's mode, never from an event payload.
   */
  scheduleRefresh() {
    clearTimeout(this._refreshTimer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._refreshTimer = setTimeout(() => {
      this._refreshTimer = undefined;
      if (this.boardResult) {
        refreshApex(this.boardResult);
      }
    }, REFRESH_DEBOUNCE_MS);
  }

  get liveLabel() {
    return this.isLive ? "Live" : "";
  }

  /** Blank means every work item the user can see, not "items with no project". */
  @api
  get projectId() {
    return this._projectId;
  }
  set projectId(value) {
    this._projectId =
      value && String(value).trim() ? String(value).trim() : null;
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

  @wire(getBoardData, { projectId: "$_projectId" })
  wiredBoard(result) {
    this.boardResult = result;
    if (result.data) {
      this.board = result.data;
      this.errorMessage = undefined;
      this.isLoading = false;
      this.rebuild();
    } else if (result.error) {
      this.board = undefined;
      this.rebuild();
      this.errorMessage = this.readError(result.error);
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
  get hasOutside() {
    return this.outsideCards.length > 0;
  }
  get hasOutsideEpics() {
    return this.outsideEpics.length > 0;
  }
  get headingLabel() {
    return this.board && this.board.projectLabel
      ? this.board.projectLabel
      : "All work items";
  }
  get freshnessLabel() {
    if (!this.board || !this.board.lastSyncedAt) {
      return "Never synced";
    }
    const when = new Date(this.board.lastSyncedAt);
    return `Last synced ${when.toLocaleString()}`;
  }
  // What is on screen, after the filters - not what the payload holds.
  get countLabel() {
    return this.isEpicView
      ? epicViewCountLabel(this.epicCount, this.epicEntryCount - this.epicCount)
      : countLabel(this.allCards.length, "item", "items");
  }

  // ---------- filters ----------

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

  get isTaskView() {
    return this.view === VIEW_TASKS;
  }
  get isEpicView() {
    return this.view === VIEW_EPICS;
  }
  get isFiltered() {
    return this.source !== ALL_SOURCES;
  }
  get isTaskViewEmpty() {
    return this.allCards.length === 0;
  }
  get isEpicViewEmpty() {
    return this.epicEntryCount === 0;
  }
  get filteredEmptyTitle() {
    return `Nothing from ${this.source} here.`;
  }

  // ---------- view model ----------

  get configuredColumns() {
    return columnsFrom(this._columnsRaw);
  }

  /** Both views' layouts, from the payload through the Source filter. */
  rebuild() {
    const items = (this.board && this.board.items) || [];
    const epics = (this.board && this.board.epics) || [];
    this.sourceChoices = sourceOptions(items, epics);
    this.source = keptSource(this.source, this.sourceChoices);
    const shownItems = bySource(items, this.source);

    this.rebuildEpics(bySource(epics, this.source), shownItems);

    const cards = shownItems.map((item) => this.toCard(item));
    const byId = new Map(cards.map((card) => [card.id, card]));

    // Resolve parents before bucketing, so a child can tell whether its parent is on this
    // board at all. An orphan - parent filtered out, or deleted - must still render.
    cards.forEach((card) => {
      const parent = card.parentId ? byId.get(card.parentId) : undefined;
      // The key the source knows the parent by, or its record number when it has none.
      card.parentKey = parent
        ? parent.externalKey || parent.recordNumber
        : null;
      card.isOrphan = !!card.parentId && !parent;
    });

    // Nest a child under its parent only when both sit in this column. A child in a
    // different column belongs in its own column and gets a parent note instead -
    // nesting it here would put an In Progress card under a To Do heading.
    const laid = layoutColumns(cards, this.configuredColumns, (inColumn) => {
      const { tops, idsHere } = nestByParent(
        inColumn,
        (card) => card.id,
        (card) => card.parentId
      );
      tops.forEach((card) => this.annotateParent(card, idsHere));
      return tops;
    });
    this.viewColumns = laid.columns;
    this.allCards = cards;

    const outside = laid.other;
    outside.forEach((card) => this.annotateParent(card, new Set()));
    this.outsideCards = outside;
  }

  /**
   * The Epics view, by the same rules as the public board's: epics from EpicRollup on the
   * server, and every card whose source does not roll up into epics passing through untouched
   * into the column its own status names.
   */
  rebuildEpics(epics, items) {
    const entries = [
      ...epics.map((epic) => epicModel(epic, { key: `epic-${epic.id}` })),
      ...items
        .filter((item) => !item.condensesIntoEpic)
        .map((item) => this.toCard(item))
    ];
    const laid = layoutColumns(entries, this.configuredColumns);
    this.epicColumns = laid.columns.map((col) => ({
      ...col,
      emptyLabel: col.key === DONE ? "No completed epics yet" : "No epics here"
    }));
    this.outsideEpics = laid.other;
    this.epicEntryCount = entries.length;
    this.epicCount = epics.length;
  }

  /**
   * The note under a card explaining where its parent is. Three cases, all of which have to
   * render without breaking: no parent, parent on the board, parent gone.
   */
  annotateParent(card, idsInSameColumn) {
    if (!card.parentId) {
      card.showParentNote = false;
      card.parentNote = null;
      return;
    }
    if (card.isOrphan) {
      card.parentNote = "Parent is not on this board";
    } else if (idsInSameColumn.has(card.parentId)) {
      card.parentNote = null;
    } else {
      card.parentNote = `Child of ${card.parentKey}`;
    }
    card.showParentNote = !!card.parentNote;
  }

  /**
   * One card's view model: the shared collapsed card from boardModel, plus what only this
   * board uses - the id it selects by, the parent it nests under, and the detail panel's facts.
   * Overdue is shown here and not on the public board, which shows dates rather than verdicts.
   */
  toCard(item) {
    const card = cardModel(item, { key: item.id, showOverdue: true });
    return Object.assign(card, {
      id: item.id,
      parentId: item.parentId || null,
      parentKey: null,
      isOrphan: false,
      identLabel: card.ids.map((id) => id.text).join(" · "),
      // No sync state at all means the record has no remote record and never pushes.
      syncLabel: item.syncStatus || "No remote record"
    });
  }

  // ---------- selection and status change ----------

  get selectedCard() {
    if (!this.selectedId) {
      return null;
    }
    // Resolved by id rather than held as an object: refreshApex rebuilds every card, so a
    // stored reference would silently go stale after a save.
    return this.allCards.find((card) => card.id === this.selectedId) || null;
  }

  get hasSelection() {
    return !!this.selectedCard;
  }

  /**
   * The statuses offered are the configured columns minus the one the card is already in.
   * Driving this from the same configuration as the columns means a status the board does not
   * show is a status nobody can pick - which is why the unreachable In Review never appears.
   */
  get statusOptions() {
    const card = this.selectedCard;
    if (!card) {
      return [];
    }
    return this.configuredColumns
      .filter((status) => status !== card.status)
      .map((status) => ({ key: status, label: status }));
  }

  get hasStatusOptions() {
    return this.statusOptions.length > 0;
  }

  get detailTitle() {
    const card = this.selectedCard;
    return card ? card.heading : "";
  }

  handleCardSelect(event) {
    this.selectedId = event.detail.key;
    this.actionMessage = undefined;
    this.actionError = undefined;
  }

  handleCloseDetail() {
    this.selectedId = null;
    this.actionMessage = undefined;
    this.actionError = undefined;
  }

  async handleStatusClick(event) {
    const newStatus = event.currentTarget.dataset.status;
    const card = this.selectedCard;
    if (!card || !newStatus || this.isSaving) {
      return;
    }

    this.isSaving = true;
    this.actionMessage = undefined;
    this.actionError = undefined;
    try {
      const result = await changeStatus({ workItemId: card.id, newStatus });
      // Report what actually happened locally, and do not imply the source system has agreed
      // yet. Generic until build 08 step 7, which names it from the card's source label.
      this.actionMessage = result.pushQueued
        ? `${result.message} This card stays ${result.syncStatus} until the source system confirms.`
        : result.message;
      await refreshApex(this.boardResult);
    } catch (error) {
      this.actionError = this.readError(error);
    } finally {
      this.isSaving = false;
    }
  }

  readError(error) {
    if (!error) {
      return "Unknown error.";
    }
    if (Array.isArray(error.body)) {
      return error.body.map((entry) => entry.message).join(", ");
    }
    if (error.body && error.body.message) {
      return error.body.message;
    }
    return error.message || "Unknown error.";
  }
}
