/**
 * Layout helpers shared by both boards.
 *
 * This module imports no Apex, and that is the whole reason it can be shared. workItemBoard and
 * publicWorkItemBoard stay separate components because an LWC import is not conditional: a
 * component that imported WorkItemBoardController would drag the class a guest must never reach
 * into the public bundle whichever branch ran. These functions take plain arrays and return
 * plain objects, so importing them widens nothing.
 *
 * Everything here is pure. No wire, no state, no DOM.
 */
export const DEFAULT_COLUMNS = "To Do,In Progress,Done";

/**
 * The portrait layout's condition: one column at a time. A tall, narrow desktop window matches it
 * too, which is intended. Drag-and-drop runs only when it does not match.
 */
export const PORTRAIT_QUERY = "(orientation: portrait) and (max-width: 700px)";

/** A mouse or trackpad. Drag-and-drop needs one; touch drag is out of scope for build 08. */
export const FINE_POINTER_QUERY = "(pointer: fine)";

/**
 * The configured column list: an ordered, comma separated string of Status__c values, as a page
 * property provides it. Blank falls back to the default rather than to no columns at all.
 */
export function columnsFrom(raw) {
  const source = raw && String(raw).trim() ? String(raw) : DEFAULT_COLUMNS;
  return source
    .split(",")
    .map((name) => name.trim())
    .filter((name) => name.length > 0);
}

/**
 * Lay a set of cards into the configured status columns, plus whatever the columns do not
 * account for. Nothing is dropped: a card whose status is not a configured column comes back in
 * `other`, so a record never silently vanishes from either board.
 *
 * `decorate` is how a view adds its own per-column arrangement, such as nesting children under
 * parents. It receives the cards in one column and returns the cards to render at the top level.
 */
export function layoutColumns(cards, configured, decorate) {
  const configuredSet = new Set(configured);
  const columns = configured.map((status) => {
    const inColumn = cards.filter((card) => card.status === status);
    return {
      key: status,
      label: status,
      count: inColumn.length,
      countLabel: `${inColumn.length}`,
      isEmpty: inColumn.length === 0,
      cards: decorate ? decorate(inColumn) : inColumn
    };
  });
  return {
    columns,
    other: cards.filter((card) => !configuredSet.has(card.status))
  };
}

/**
 * Nest children under parents, but only when both sit in the same column. A child whose parent
 * is elsewhere stands on its own at the top level - nesting it would put an In Progress card
 * under a To Do heading.
 *
 * `idOf` and `parentOf` read the identity fields, because the two boards key on different
 * things: the internal board on Salesforce ids, the public board on auto numbers, since it
 * publishes no ids at all.
 *
 * Mutates each top-level card's `children` and `hasChildren`. Returns the top-level cards and
 * the set of ids present in the column, which the caller may need for its own annotations.
 */
export function nestByParent(inColumn, idOf, parentOf) {
  const idsHere = new Set(inColumn.map(idOf));
  const tops = inColumn.filter((card) => {
    const parentId = parentOf(card);
    return !parentId || !idsHere.has(parentId);
  });
  tops.forEach((card) => {
    card.children = inColumn.filter((other) => parentOf(other) === idOf(card));
    card.hasChildren = card.children.length > 0;
  });
  return { tops, idsHere };
}
