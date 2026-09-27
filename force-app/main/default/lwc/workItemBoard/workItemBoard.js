import { LightningElement, api, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import { subscribe, unsubscribe, onError } from "lightning/empApi";
import { NavigationMixin } from "lightning/navigation";
import getBoardData from "@salesforce/apex/WorkItemBoardController.getBoardData";
import changeStatus from "@salesforce/apex/WorkItemBoardController.changeStatus";
import saveDetails from "@salesforce/apex/WorkItemBoardController.saveDetails";
import retryPush from "@salesforce/apex/WorkItemBoardController.retryPush";
import featureEpic from "@salesforce/apex/WorkItemBoardController.featureEpic";
import unfeatureEpic from "@salesforce/apex/WorkItemBoardController.unfeatureEpic";
import {
  DEFAULT_COLUMNS,
  columnsFrom,
  layoutColumns,
  nestByParent,
  PORTRAIT_QUERY,
  FINE_POINTER_QUERY
} from "c/boardLayout";
import {
  VIEW_TASKS,
  VIEW_EPICS,
  ALL_SOURCES,
  SORT_DUE,
  SORT_PRIORITY,
  DEFAULT_SORT,
  sortCards,
  cardModel,
  epicModel,
  sourceOptions,
  bySource,
  keptSource,
  countLabel,
  epicViewCountLabel,
  sourceName,
  syncNote,
  FEATURED_LABEL_INTERNAL
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
export default class WorkItemBoard extends NavigationMixin(LightningElement) {
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
  /** Build 09. Display state: every visit opens on Due date (decision 8). */
  sort = DEFAULT_SORT;
  source = ALL_SOURCES;
  sourceChoices = [];

  allCards = [];

  // The open card - one at a time, on either view - and what the board has to tell it.
  expandedKey = null;
  feedback;
  recordLink;
  // What this board's cards may do. The public board passes none of it: its cards open and
  // show more, and that is all. Rebuilt with the data, so it is one object between renders.
  abilities;
  _focusTarget;

  // Drag-and-drop. Only with a fine pointer and outside the portrait layout; the Move to buttons
  // are the alternative everywhere else, and for anyone who does not drag (WCAG 2.5.7).
  canDrag = false;
  boardMessage = "";
  boardMessageTone = "ok";
  _drag;
  _media = [];
  _onMediaChange;

  // Live updates. The subscription is the container's alone: the shared components never import
  // lightning/empApi, which LWR sites do not support, and the public board polls instead.
  isLive = false;
  _subscription;
  _refreshTimer;
  _connected = false;

  connectedCallback() {
    this._connected = true;
    this.watchPointer();
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
    this._media.forEach((query) =>
      query.removeEventListener("change", this._onMediaChange)
    );
    this._media = [];
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

  /**
   * Re-sorts what is already held (decision 5). Kept on the board, so a live refresh's rebuild,
   * a filter change and a moved card all land in the chosen order.
   */
  handleSortChange(event) {
    const next = event.detail.value;
    if (next === SORT_DUE || next === SORT_PRIORITY) {
      this.sort = next;
      this.rebuild();
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

    this.abilities = this.board
      ? {
          moveTo: this.configuredColumns,
          edit: true,
          retry: true,
          drag: this.canDrag,
          openRecord: !!this.board.canOpenRecord,
          // Build 10: the epic card's Feature / Remove button. Portfolio_HQ_Feature_Epic, checked
          // again by the controller.
          featureEpic: !!this.board.canFeatureEpic,
          titleMax: this.board.titleMaxLength,
          priorityOptions: this.board.priorityOptions || []
        }
      : undefined;
    // Every item on the board, before the filter, so an open card can name its parent even
    // when the filter has hidden it.
    this._itemsById = new Map(items.map((item) => [item.id, item]));

    this.rebuildEpics(bySource(epics, this.source), shownItems);

    // Sorted before the layout, which keeps the order when it buckets and when it nests: top-level
    // cards sort, children sort within their parent, and a moved card lands in its sorted place.
    const cards = sortCards(
      shownItems.map((item) => this.toCard(item)),
      this.sort
    );
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
      ...epics.map((epic) =>
        epicModel(epic, {
          key: `epic-${epic.id}`,
          featuredLabel: FEATURED_LABEL_INTERNAL
        })
      ),
      // Epics keep their order (decision 7); the cards passing through sort, after them.
      ...sortCards(
        items
          .filter((item) => !item.condensesIntoEpic)
          .map((item) => this.toCard(item)),
        this.sort
      )
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
      parentLine: this.parentLine(item),
      syncNote: syncNote(item)
    });
  }

  /** The expanded card's "Part of" line: the parent's number and title, when it has one. */
  parentLine(item) {
    if (!item.parentId) {
      return null;
    }
    const parent = this._itemsById && this._itemsById.get(item.parentId);
    if (!parent) {
      return "A work item that is not on this board";
    }
    return parent.title
      ? `${parent.recordNumber} ${parent.title}`
      : parent.recordNumber;
  }

  // ---------- the open card ----------

  /** Cards are keyed by record id; epic cards by "epic-" and the epic's id. */
  recordIdFor(key) {
    return key && key.startsWith("epic-") ? key.slice(5) : key;
  }

  sourceLabelFor(key) {
    const item = this._itemsById && this._itemsById.get(this.recordIdFor(key));
    return item ? item.sourceLabel : null;
  }

  /** One card open at a time: opening one closes the other, and a second click closes it. */
  handleToggle(event) {
    const key = event.detail.key;
    this.expandedKey = this.expandedKey === key ? null : key;
    this.feedback = undefined;
    this.recordLink = undefined;
    if (this.expandedKey && this.abilities && this.abilities.openRecord) {
      this.makeRecordLink(this.expandedKey);
    }
  }

  /** A real href for the admin link, so it opens a new tab like any link when asked to. */
  makeRecordLink(key) {
    this[NavigationMixin.GenerateUrl](this.recordPage(key)).then((url) => {
      // Only if that card is still the open one: a quick second toggle must not inherit it.
      if (this.expandedKey === key) {
        this.recordLink = { key, url };
      }
    });
  }

  recordPage(key) {
    return {
      type: "standard__recordPage",
      attributes: {
        recordId: this.recordIdFor(key),
        objectApiName: "Work_Item__c",
        actionName: "view"
      }
    };
  }

  handleOpenRecord(event) {
    this[NavigationMixin.Navigate](this.recordPage(event.detail.key));
  }

  /** The Move to buttons. */
  handleMove(event) {
    const { key, status } = event.detail;
    return this.moveCard(key, status, false);
  }

  /**
   * Moves a card, from Move to or from a drop. changeStatus writes Status__c and the trigger
   * queues the push; this reports what Salesforce did and that the source has not confirmed yet.
   *
   * The card does not move until Salesforce has committed: it stays in its column, dimmed, while
   * the save runs, and the refresh that follows puts it in the new one. A save that fails leaves
   * it where it was - the snap back is simply never having left. After Move to, focus follows the
   * card to its new column; after a drop, the board says what happened in a status line, because
   * a closed card has nowhere to say it.
   */
  async moveCard(key, status, dragged) {
    const number = this.recordNumberFor(key);
    this.feedback = { key, busy: true };
    if (dragged) {
      this.announce(`Moving ${number} to ${status}…`, "ok");
    }
    try {
      const result = await changeStatus({ workItemId: key, newStatus: status });
      const message = result.pushQueued
        ? `${result.message} This card stays ${result.syncStatus} until ${sourceName(
            this.sourceLabelFor(key)
          )} confirms.`
        : result.message;
      // Focus follows the card once it has rendered in its new column - not before, when the
      // first render after this one still shows it in the old one.
      this._focusTarget = dragged ? undefined : { key, status: result.status };
      this.feedback = { key, tone: "ok", message };
      if (dragged) {
        this.announce(`${number} moved to ${result.status}. ${message}`, "ok");
      }
      await refreshApex(this.boardResult);
    } catch (error) {
      this._focusTarget = undefined;
      const reason = this.readError(error);
      this.feedback = { key, tone: "error", message: reason };
      if (dragged) {
        this.announce(`${number} was not moved. ${reason}`, "error");
      }
    }
  }

  /**
   * Retry: sends a refused change again. retryPush moves Sync_Status__c from Failed to Pending and
   * the trigger queues the push, as for any save; nothing here calls the sync service.
   */
  async handleRetry(event) {
    const key = event.detail.key;
    this.feedback = { key, busy: true };
    try {
      const result = await retryPush({ workItemId: key });
      this.feedback = { key, tone: "ok", message: result.message };
      if (result.pushQueued) {
        await refreshApex(this.boardResult);
      }
    } catch (error) {
      this.feedback = { key, tone: "error", message: this.readError(error) };
    }
  }

  /**
   * The open epic card's Feature or Remove (build 10). The controller writes the featured epic's
   * setting and nothing else - no work item, so nothing is pushed - and answers in words: a
   * refusal, such as an epic that is not public, is shown as an error on the card. The board then
   * refreshes itself, because Change Data Capture does not fire for a custom setting: this board
   * sees the change at once, and other open tabs on their next refresh (decision 14). Remove sends
   * the epic it was pressed on, and changes nothing if another epic was featured meanwhile.
   */
  async handleFeature(event) {
    const { key, feature } = event.detail;
    const epicId = this.recordIdFor(key);
    this.feedback = { key, busy: true };
    try {
      const result = feature
        ? await featureEpic({ epicId })
        : await unfeatureEpic({ epicId });
      this.feedback = {
        key,
        tone: result.refused ? "error" : "ok",
        message: result.message
      };
      await refreshApex(this.boardResult);
    } catch (error) {
      this.feedback = { key, tone: "error", message: this.readError(error) };
    }
  }

  announce(message, tone) {
    this.boardMessage = message;
    this.boardMessageTone = tone;
  }

  get boardMessageClass() {
    return this.boardMessageTone === "error"
      ? "board-message board-message-error"
      : "board-message";
  }

  recordNumberFor(key) {
    const item = this._itemsById && this._itemsById.get(this.recordIdFor(key));
    return item ? item.recordNumber : "The card";
  }

  // ---------- drag-and-drop ----------

  /**
   * Drag needs a mouse or trackpad and the landscape layout, and both can change while the page
   * is open - a window resized into portrait, a tablet with a keyboard attached. The abilities
   * are updated when either does, so a card never offers a drag the layout cannot take.
   */
  watchPointer() {
    if (typeof window.matchMedia !== "function") {
      this.canDrag = false;
      return;
    }
    this._media = [
      window.matchMedia(FINE_POINTER_QUERY),
      window.matchMedia(PORTRAIT_QUERY)
    ];
    this._onMediaChange = () => this.updateDrag();
    this._media.forEach((query) =>
      query.addEventListener("change", this._onMediaChange)
    );
    this.updateDrag();
  }

  updateDrag() {
    const [fine, portrait] = this._media;
    const can = !!fine && fine.matches && !(portrait && portrait.matches);
    if (can === this.canDrag) {
      return;
    }
    this.canDrag = can;
    if (this.abilities) {
      this.abilities = { ...this.abilities, drag: can };
    }
  }

  handleCardDragStart(event) {
    this._drag = { key: event.detail.key, status: event.detail.status };
  }

  handleCardDragEnd() {
    this._drag = undefined;
    this.clearDropTargets();
  }

  columnStatus(element) {
    return element.dataset.column || element.dataset.epicColumn;
  }

  /**
   * A column accepts a card from another column. Its own column is not a drop target, so the
   * browser shows no drop there and dropping does nothing.
   */
  handleDragOver(event) {
    if (!this._drag) {
      return;
    }
    const column = event.currentTarget;
    if (this.columnStatus(column) === this._drag.status) {
      return;
    }
    event.preventDefault();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "move";
    }
    if (!column.hasAttribute("data-drop-target")) {
      this.clearDropTargets();
      column.setAttribute("data-drop-target", "");
    }
  }

  handleDragLeave(event) {
    const column = event.currentTarget;
    if (!event.relatedTarget || !column.contains(event.relatedTarget)) {
      column.removeAttribute("data-drop-target");
    }
  }

  /** The dragged record alone changes status - never its children, which keep their own. */
  handleDrop(event) {
    event.preventDefault();
    const drag = this._drag;
    this._drag = undefined;
    this.clearDropTargets();
    const status = this.columnStatus(event.currentTarget);
    if (!drag || !status || status === drag.status) {
      return undefined;
    }
    return this.moveCard(drag.key, status, true);
  }

  clearDropTargets() {
    this.template
      .querySelectorAll("[data-drop-target]")
      .forEach((column) => column.removeAttribute("data-drop-target"));
  }

  /**
   * Save changes. The card has already checked the draft; the server checks it again and its
   * answer is the one that counts. Problems come back per field and the card shows each beside
   * its input; a save that went through says so and that the push is still running.
   */
  async handleSave(event) {
    const { key, title, startDate, dueDate, priority } = event.detail;
    this.feedback = { key, busy: true };
    try {
      const params = { workItemId: key, title, startDate, dueDate };
      // Only when the card sent one. Absent reaches Apex as null, "leave it alone"; an empty
      // string is "No priority" and clears it.
      if (priority !== undefined) {
        params.priority = priority;
      }
      const result = await saveDetails(params);
      const fieldErrors = result.fieldErrors || {};
      this.feedback = {
        key,
        tone: Object.keys(fieldErrors).length ? "error" : "ok",
        saved: !!result.saved,
        message: result.message,
        fieldErrors
      };
      if (result.saved) {
        await refreshApex(this.boardResult);
      }
    } catch (error) {
      this.feedback = { key, tone: "error", message: this.readError(error) };
    }
  }

  renderedCallback() {
    if (!this._focusTarget) {
      return;
    }
    const { key, status } = this._focusTarget;
    const moved = this.template.querySelector(
      `c-board-card[data-key="${key}"][data-status="${status}"]`
    );
    if (moved) {
      this._focusTarget = undefined;
      moved.focusHeader();
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
