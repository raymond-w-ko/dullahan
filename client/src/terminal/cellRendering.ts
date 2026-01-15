// Cell rendering utilities
// Converts terminal cells to styled text runs for rendering

import { cellToChar } from "../../../protocol/schema/cell";
import { getStyle } from "../../../protocol/schema/style";
import type { Cell } from "../../../protocol/schema/cell";
import type { Style, StyleTable } from "../../../protocol/schema/style";

/** A run of consecutive cells with the same style */
export interface StyledRun {
  text: string;
  styleId: number;
  style: Style;
}

/** Convert cells to lines of styled runs */
export function cellsToRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  rows: number
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

      if (currentRun && currentRun.styleId === styleId) {
        currentRun.text += char;
      } else {
        const style = getStyle(styles, styleId);
        currentRun = { text: char, styleId, style };
        runs.push(currentRun);
      }
    }

    lines.push(runs);
  }

  return lines;
}
