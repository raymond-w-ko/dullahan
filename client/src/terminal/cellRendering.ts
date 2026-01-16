// Cell rendering utilities
// Converts terminal cells to styled text runs for rendering

import { cellToChar } from "../../../protocol/schema/cell";
import { getStyle } from "../../../protocol/schema/style";
import type { Cell } from "../../../protocol/schema/cell";
import type { Style, StyleTable } from "../../../protocol/schema/style";
import type { SelectionBounds } from "../../../protocol/schema/messages";

/** A run of consecutive cells with the same style */
export interface StyledRun {
  text: string;
  styleId: number;
  style: Style;
  selected?: boolean; // True if this run is within selection
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
  let startX = selection.startX;
  let startY = selection.startY;
  let endX = selection.endX;
  let endY = selection.endY;

  // Swap if start is after end (for reversed selection)
  if (startY > endY || (startY === endY && startX > endX)) {
    [startX, endX] = [endX, startX];
    [startY, endY] = [endY, startY];
  }

  if (selection.isRectangle) {
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
 */
export function cellsToRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  rows: number,
  selection?: SelectionBounds
): StyledRun[][] {
  const lines: StyledRun[][] = [];

  for (let y = 0; y < rows; y++) {
    const runs: StyledRun[] = [];
    let currentRun: StyledRun | null = null;

    for (let x = 0; x < cols; x++) {
      const idx = y * cols + x;
      const cell = cells[idx];
      const char = cell ? cellToChar(cell) : " ";
      const styleId = cell?.styleId ?? 0;
      const selected = selection ? isCellInSelection(x, y, selection) : false;

      // Start a new run if style or selection state changes
      if (
        currentRun &&
        currentRun.styleId === styleId &&
        currentRun.selected === selected
      ) {
        currentRun.text += char;
      } else {
        const style = getStyle(styles, styleId);
        currentRun = { text: char, styleId, style, selected };
        runs.push(currentRun);
      }
    }

    lines.push(runs);
  }

  return lines;
}
