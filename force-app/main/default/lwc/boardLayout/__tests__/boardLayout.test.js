import {
  DEFAULT_COLUMNS,
  columnsFrom,
  layoutColumns,
  nestByParent
} from "c/boardLayout";

const card = (id, status, parentId = null) => ({ id, status, parentId });
const idOf = (c) => c.id;
const parentOf = (c) => c.parentId;

describe("c-board-layout", () => {
  describe("columnsFrom", () => {
    it("splits, trims and drops empties", () => {
      expect(columnsFrom(" To Do , In Progress,,Done ")).toEqual([
        "To Do",
        "In Progress",
        "Done"
      ]);
    });

    it("falls back to the default when blank, so a misconfigured page still shows a board", () => {
      expect(columnsFrom("")).toEqual(DEFAULT_COLUMNS.split(","));
      expect(columnsFrom("   ")).toEqual(DEFAULT_COLUMNS.split(","));
      expect(columnsFrom(null)).toEqual(DEFAULT_COLUMNS.split(","));
      expect(columnsFrom(undefined)).toEqual(DEFAULT_COLUMNS.split(","));
    });
  });

  describe("layoutColumns", () => {
    it("buckets by status in configured order and reports counts", () => {
      const laid = layoutColumns(
        [card("a", "Done"), card("b", "To Do"), card("c", "To Do")],
        ["To Do", "Done"]
      );
      expect(laid.columns.map((c) => c.key)).toEqual(["To Do", "Done"]);
      expect(laid.columns[0].cards.map(idOf)).toEqual(["b", "c"]);
      expect(laid.columns[0].count).toBe(2);
      expect(laid.columns[0].countLabel).toBe("2");
      expect(laid.columns[0].isEmpty).toBe(false);
      expect(laid.columns[1].cards.map(idOf)).toEqual(["a"]);
    });

    it("marks an empty column rather than omitting it", () => {
      const laid = layoutColumns([card("a", "Done")], ["To Do", "Done"]);
      expect(laid.columns[0].isEmpty).toBe(true);
      expect(laid.columns[0].cards).toEqual([]);
    });

    it("never drops a card: unaccounted statuses come back as other", () => {
      const laid = layoutColumns(
        [card("a", "Unspecified"), card("b", "To Do")],
        ["To Do"]
      );
      expect(laid.other.map(idOf)).toEqual(["a"]);
    });

    it("hands each column to the decorator and renders what it returns", () => {
      const seen = [];
      const laid = layoutColumns(
        [card("a", "To Do"), card("b", "To Do")],
        ["To Do"],
        (inColumn) => {
          seen.push(inColumn.map(idOf));
          return inColumn.slice(0, 1);
        }
      );
      expect(seen).toEqual([["a", "b"]]);
      expect(laid.columns[0].cards.map(idOf)).toEqual(["a"]);
      // The count is the column's true size, not the decorated top level.
      expect(laid.columns[0].count).toBe(2);
    });
  });

  describe("nestByParent", () => {
    it("nests a child under a parent in the same column", () => {
      const parent = card("p", "To Do");
      const child = card("c", "To Do", "p");
      const { tops, idsHere } = nestByParent([parent, child], idOf, parentOf);
      expect(tops).toEqual([parent]);
      expect(parent.hasChildren).toBe(true);
      expect(parent.children).toEqual([child]);
      expect(idsHere).toEqual(new Set(["p", "c"]));
    });

    it("keeps a child at the top level when its parent is not in this column", () => {
      const child = card("c", "To Do", "elsewhere");
      const { tops } = nestByParent([child], idOf, parentOf);
      expect(tops).toEqual([child]);
      expect(child.hasChildren).toBe(false);
    });

    it("keys on whatever the caller says is identity", () => {
      const parent = {
        recordNumber: "WI-0001",
        parentNumber: null,
        status: "Done"
      };
      const child = {
        recordNumber: "WI-0002",
        parentNumber: "WI-0001",
        status: "Done"
      };
      const { tops } = nestByParent(
        [parent, child],
        (c) => c.recordNumber,
        (c) => c.parentNumber
      );
      expect(tops).toEqual([parent]);
      expect(parent.children).toEqual([child]);
    });
  });
});
