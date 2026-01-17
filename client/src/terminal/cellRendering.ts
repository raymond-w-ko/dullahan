// Cell rendering utilities
// Converts terminal cells to styled text runs for rendering

import { cellToChar, ContentTag, Wide } from "../../../protocol/schema/cell";
import { getStyle, ColorTag } from "../../../protocol/schema/style";
import type { Cell, HyperlinkTable } from "../../../protocol/schema/cell";
import type { Style, StyleTable, Color } from "../../../protocol/schema/style";
import {
  normalizeSelectionBounds,
  type SelectionBounds,
} from "../../../protocol/schema/messages";

/** A run of consecutive cells with the same style */
export interface StyledRun {
  text: string;
  styleId: number;
  style: Style;
  selected?: boolean; // True if this run is within selection
  bgOverride?: Color; // Cell content-based bg color (BG_COLOR_PALETTE/RGB)
  hyperlink?: string; // URL for OSC 8 hyperlinks
}

/**
 * Extract background color from cell content if present.
 * Ghostty stores bg-only cells (like htop's colored headers) with content_tag 2 or 3.
 */
function getCellContentBgColor(cell: Cell): Color | undefined {
  if (cell.content.tag === ContentTag.BG_COLOR_PALETTE) {
    return { tag: ColorTag.PALETTE, index: cell.content.palette };
  }
  if (cell.content.tag === ContentTag.BG_COLOR_RGB) {
    return {
      tag: ColorTag.RGB,
      r: cell.content.rgb.r,
      g: cell.content.rgb.g,
      b: cell.content.rgb.b,
    };
  }
  return undefined;
}

/**
 * Compare two optional colors for equality.
 */
function colorsEqual(a: Color | undefined, b: Color | undefined): boolean {
  if (a === undefined && b === undefined) return true;
  if (a === undefined || b === undefined) return false;
  if (a.tag !== b.tag) return false;
  if (a.tag === ColorTag.NONE) return true;
  if (a.tag === ColorTag.PALETTE && b.tag === ColorTag.PALETTE) {
    return a.index === b.index;
  }
  if (a.tag === ColorTag.RGB && b.tag === ColorTag.RGB) {
    return a.r === b.r && a.g === b.g && a.b === b.b;
  }
  return false;
}

/**
 * Check if a cell at (x, y) is within the selection bounds.
 * Handles both normal (line) selection and rectangular selection.
 *
 * For normal selection: cells are selected if they're on rows between
 * startY and endY, with partial selection on start/end rows.
 *
 * For rectangular selection: cells are selected if they're within
 * the rectangle defined by the start and end corners.
 */
export function isCellInSelection(
  x: number,
  y: number,
  selection: SelectionBounds
): boolean {
  // Normalize so start is before end
  const { startX, startY, endX, endY, isRectangle } =
    normalizeSelectionBounds(selection);

  if (isRectangle) {
    // Rectangle selection: cell is in if x is between startX/endX
    // and y is between startY/endY
    const minX = Math.min(startX, endX);
    const maxX = Math.max(startX, endX);
    return y >= startY && y <= endY && x >= minX && x <= maxX;
  } else {
    // Normal (line) selection
    if (y < startY || y > endY) {
      return false;
    }
    if (y === startY && y === endY) {
      // Single line: between start and end
      return x >= startX && x <= endX;
    }
    if (y === startY) {
      // First line: from startX to end of line
      return x >= startX;
    }
    if (y === endY) {
      // Last line: from start of line to endX
      return x <= endX;
    }
    // Middle lines: entire line is selected
    return true;
  }
}

/**
 * Convert cells to lines of styled runs.
 * If selection is provided, runs will be split at selection boundaries
 * and have their `selected` property set accordingly.
 * If hyperlinks is provided, runs will be split at hyperlink boundaries.
 */
export function cellsToRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  rows: number,
  selection?: SelectionBounds,
  hyperlinks?: HyperlinkTable
): StyledRun[][] {
  const lines: StyledRun[][] = [];

  for (let y = 0; y < rows; y++) {
    const runs: StyledRun[] = [];
    let currentRun: StyledRun | null = null;

    for (let x = 0; x < cols; x++) {
      const idx = y * cols + x;
      const cell = cells[idx];

      // Skip spacer cells (second half of wide characters)
      if (cell && (cell.wide === Wide.SPACER_TAIL || cell.wide === Wide.SPACER_HEAD)) {
        continue;
      }

      const char = cell ? cellToChar(cell) : " ";
      const styleId = cell?.styleId ?? 0;
      const selected = selection ? isCellInSelection(x, y, selection) : false;
      // Extract content-based bg color (for bg-only cells like htop headers)
      const bgOverride = cell ? getCellContentBgColor(cell) : undefined;
      // Get hyperlink URL if this cell is part of a hyperlink
      const hyperlink = (cell?.hyperlink && hyperlinks) ? hyperlinks.get(idx) : undefined;

      // Start a new run if style, selection, bgOverride, or hyperlink changes
      if (
        currentRun &&
        currentRun.styleId === styleId &&
        currentRun.selected === selected &&
        colorsEqual(currentRun.bgOverride, bgOverride) &&
        currentRun.hyperlink === hyperlink
      ) {
        currentRun.text += char;
      } else {
        const style = getStyle(styles, styleId);
        currentRun = { text: char, styleId, style, selected, bgOverride, hyperlink };
        runs.push(currentRun);
      }
    }

    lines.push(runs);
  }

  return lines;
}
