/**
 * Tests for cell rendering utilities.
 */

import { describe, test, expect } from "bun:test";
import { cellsToRuns, isCellInSelection } from "./cellRendering";
import { ContentTag, Wide } from "../../../protocol/schema/cell";
import type { Cell } from "../../../protocol/schema/cell";
import type { StyleTable } from "../../../protocol/schema/style";

/** Create a simple cell with given codepoint and wide state */
function makeCell(codepoint: number, wide: number = Wide.NARROW, styleId: number = 0): Cell {
  return {
    content: { tag: ContentTag.CODEPOINT, codepoint },
    styleId,
    wide: wide as Cell["wide"],
    protected: false,
    hyperlink: false,
  };
}

/** Empty style table for tests (just has default style at id 0) */
const emptyStyles: StyleTable = new Map();

describe("cellsToRuns", () => {
  test("simple ASCII row", () => {
    const cells = [
      makeCell(72),  // H
      makeCell(105), // i
      makeCell(33),  // !
    ];

    const lines = cellsToRuns(cells, emptyStyles, 3, 1);

    expect(lines.length).toBe(1);
    expect(lines[0]!.length).toBe(1); // All same style, one run
    expect(lines[0]![0]!.text).toBe("Hi!");
  });

  test("wide character with SPACER_TAIL is rendered correctly", () => {
    // CJK character 中 (U+4E2D) takes 2 cells:
    // - Cell 0: wide=WIDE, contains the character
    // - Cell 1: wide=SPACER_TAIL, placeholder (should be skipped)
    const cells = [
      makeCell(0x4e2d, Wide.WIDE),       // 中
      makeCell(0, Wide.SPACER_TAIL),     // spacer (should be skipped)
      makeCell(65),                       // A
    ];

    const lines = cellsToRuns(cells, emptyStyles, 3, 1);

    expect(lines.length).toBe(1);
    expect(lines[0]!.length).toBe(1); // All same style
    // Should render "中A" not "中 A" (spacer skipped)
    expect(lines[0]![0]!.text).toBe("中A");
  });

  test("multiple wide characters", () => {
    // Two CJK characters: 中文
    const cells = [
      makeCell(0x4e2d, Wide.WIDE),       // 中
      makeCell(0, Wide.SPACER_TAIL),     // spacer
      makeCell(0x6587, Wide.WIDE),       // 文
      makeCell(0, Wide.SPACER_TAIL),     // spacer
    ];

    const lines = cellsToRuns(cells, emptyStyles, 4, 1);

    expect(lines.length).toBe(1);
    expect(lines[0]![0]!.text).toBe("中文");
  });

  test("SPACER_HEAD keeps column alignment", () => {
    // SPACER_HEAD is used for wrapped wide chars; it should occupy a cell
    const cells = [
      makeCell(0, Wide.SPACER_HEAD),     // spacer head (should occupy space)
      makeCell(65),                       // A
      makeCell(66),                       // B
    ];

    const lines = cellsToRuns(cells, emptyStyles, 3, 1);

    expect(lines.length).toBe(1);
    expect(lines[0]![0]!.text).toBe(" AB");
  });

  test("mixed narrow and wide characters", () => {
    // "A中B" - narrow, wide+spacer, narrow
    const cells = [
      makeCell(65),                       // A
      makeCell(0x4e2d, Wide.WIDE),       // 中
      makeCell(0, Wide.SPACER_TAIL),     // spacer
      makeCell(66),                       // B
    ];

    const lines = cellsToRuns(cells, emptyStyles, 4, 1);

    expect(lines.length).toBe(1);
    expect(lines[0]![0]!.text).toBe("A中B");
  });

  test("symbol-like PUA expands when followed by whitespace", () => {
    const iconCp = 0xea61;
    const icon = String.fromCodePoint(iconCp);
    const cells = [
      makeCell(iconCp), // Nerd Font icon
      makeCell(0),      // space (whitespace)
      makeCell(65),     // A
    ];

    const lines = cellsToRuns(cells, emptyStyles, 3, 1);

    expect(lines[0]![0]!.text).toBe(`${icon}A`);
    expect(lines[0]![0]!.wideRanges).toEqual([{ start: 0, end: 1 }]);
    expect(lines[0]![0]!.singleRanges).toBeUndefined();
  });

  test("symbol-like PUA stays single when next cell is not whitespace", () => {
    const iconCp = 0xea61;
    const icon = String.fromCodePoint(iconCp);
    const cells = [
      makeCell(iconCp), // Nerd Font icon
      makeCell(66),     // B
      makeCell(65),     // A
    ];

    const lines = cellsToRuns(cells, emptyStyles, 3, 1);

    expect(lines[0]![0]!.text).toBe(`${icon}BA`);
    expect(lines[0]![0]!.wideRanges).toBeUndefined();
    expect(lines[0]![0]!.singleRanges).toEqual([{ start: 0, end: 1 }]);
  });

  test("wide characters with different styles create separate runs", () => {
    const cells = [
      makeCell(0x4e2d, Wide.WIDE, 1),    // 中 (style 1)
      makeCell(0, Wide.SPACER_TAIL, 1),  // spacer (style 1)
      makeCell(0x6587, Wide.WIDE, 2),    // 文 (style 2)
      makeCell(0, Wide.SPACER_TAIL, 2),  // spacer (style 2)
    ];

    const lines = cellsToRuns(cells, emptyStyles, 4, 1);

    expect(lines.length).toBe(1);
    expect(lines[0]!.length).toBe(2); // Two runs due to style change
    expect(lines[0]![0]!.text).toBe("中");
    expect(lines[0]![0]!.styleId).toBe(1);
    expect(lines[0]![1]!.text).toBe("文");
    expect(lines[0]![1]!.styleId).toBe(2);
  });

  test("empty cells render as spaces", () => {
    const cells = [
      makeCell(65),  // A
      makeCell(0),   // empty (codepoint 0)
      makeCell(66),  // B
    ];

    const lines = cellsToRuns(cells, emptyStyles, 3, 1);

    expect(lines[0]![0]!.text).toBe("A B");
  });

  test("multiple rows with wide characters", () => {
    // Row 0: "中A"
    // Row 1: "B文"
    const cells = [
      // Row 0
      makeCell(0x4e2d, Wide.WIDE),       // 中
      makeCell(0, Wide.SPACER_TAIL),     // spacer
      makeCell(65),                       // A
      // Row 1
      makeCell(66),                       // B
      makeCell(0x6587, Wide.WIDE),       // 文
      makeCell(0, Wide.SPACER_TAIL),     // spacer
    ];

    const lines = cellsToRuns(cells, emptyStyles, 3, 2);

    expect(lines.length).toBe(2);
    expect(lines[0]![0]!.text).toBe("中A");
    expect(lines[1]![0]!.text).toBe("B文");
  });
});

describe("isCellInSelection", () => {
  test("cell within single-line selection", () => {
    const selection = { startX: 2, startY: 0, endX: 5, endY: 0, isRectangle: false };

    expect(isCellInSelection(1, 0, selection)).toBe(false);
    expect(isCellInSelection(2, 0, selection)).toBe(true);
    expect(isCellInSelection(3, 0, selection)).toBe(true);
    expect(isCellInSelection(5, 0, selection)).toBe(true);
    expect(isCellInSelection(6, 0, selection)).toBe(false);
  });

  test("cell within multi-line selection", () => {
    const selection = { startX: 5, startY: 1, endX: 3, endY: 3, isRectangle: false };

    // Row 0: not selected
    expect(isCellInSelection(5, 0, selection)).toBe(false);

    // Row 1 (start row): from startX to end of line
    expect(isCellInSelection(4, 1, selection)).toBe(false);
    expect(isCellInSelection(5, 1, selection)).toBe(true);
    expect(isCellInSelection(10, 1, selection)).toBe(true);

    // Row 2 (middle row): entire line selected
    expect(isCellInSelection(0, 2, selection)).toBe(true);
    expect(isCellInSelection(50, 2, selection)).toBe(true);

    // Row 3 (end row): from start of line to endX
    expect(isCellInSelection(0, 3, selection)).toBe(true);
    expect(isCellInSelection(3, 3, selection)).toBe(true);
    expect(isCellInSelection(4, 3, selection)).toBe(false);
  });

  test("rectangular selection", () => {
    const selection = { startX: 2, startY: 1, endX: 5, endY: 3, isRectangle: true };

    // Outside rectangle
    expect(isCellInSelection(1, 2, selection)).toBe(false);
    expect(isCellInSelection(6, 2, selection)).toBe(false);
    expect(isCellInSelection(3, 0, selection)).toBe(false);
    expect(isCellInSelection(3, 4, selection)).toBe(false);

    // Inside rectangle
    expect(isCellInSelection(2, 1, selection)).toBe(true);
    expect(isCellInSelection(5, 3, selection)).toBe(true);
    expect(isCellInSelection(3, 2, selection)).toBe(true);
  });
});
