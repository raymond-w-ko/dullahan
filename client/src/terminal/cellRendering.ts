// Cell rendering utilities
// Converts terminal cells to styled text runs for rendering

import { cellToChar, ContentTag, Wide } from "../../../protocol/schema/cell";
import { getStyle, ColorTag } from "../../../protocol/schema/style";
import type { Cell, HyperlinkTable, GraphemeTable } from "../../../protocol/schema/cell";
import type { Style, StyleTable, Color } from "../../../protocol/schema/style";
import {
  profileHasCodepoint,
  textNeedsFontFallback,
  type FontCoverageProfile,
} from "./fontCoverage";
import {
  normalizeSelectionBounds,
  type SelectionBounds,
} from "../../../protocol/schema/messages";

/** A run of consecutive cells with the same style */
export interface StyledRun {
  text: string;
  cellCount: number;
  fixedWidth?: 1 | 2;
  styleId: number;
  style: Style;
  selected?: boolean; // True if this run is within selection
  bgOverride?: Color; // Cell content-based bg color (BG_COLOR_PALETTE/RGB)
  hyperlink?: string; // URL for OSC 8 hyperlinks
}

export interface PreparedSelection extends SelectionBounds {
  minX: number;
  maxX: number;
}

function isFastPathCell(
  cell: Cell | undefined,
  fontCoverage?: FontCoverageProfile
): boolean {
  if (!cell) return true;
  if (cell.wide !== Wide.NARROW) return false;
  if (cell.hyperlink) return false;
  if (cell.content.tag !== ContentTag.CODEPOINT) return false;
  if (cell.content.codepoint === 0) return true;
  return !fontCoverage || profileHasCodepoint(fontCoverage, cell.content.codepoint);
}

function tryBuildFastPathRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  baseOffset: number,
  fontCoverage?: FontCoverageProfile
): StyledRun[] | null {
  const runs: StyledRun[] = [];
  let currentRun: StyledRun | null = null;

  for (let x = 0; x < cols; x++) {
    const idx = baseOffset + x;
    const cell = cells[idx];
    if (!isFastPathCell(cell, fontCoverage)) {
      return null;
    }
    const char = cell ? cellToChar(cell, undefined, idx) : " ";
    const styleId = cell?.styleId ?? 0;
    if (currentRun && currentRun.styleId === styleId) {
      currentRun.text += char;
      currentRun.cellCount += 1;
      continue;
    }
    const style = getStyle(styles, styleId);
    currentRun = { text: char, cellCount: 1, styleId, style };
    runs.push(currentRun);
  }

  return runs;
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
  const prepared = prepareSelection(selection);
  if (!prepared) {
    return false;
  }
  return isCellInPreparedSelection(x, y, prepared);
}

export function prepareSelection(
  selection?: SelectionBounds
): PreparedSelection | undefined {
  if (!selection) return undefined;
  // Normalize so start is before end
  const normalized = normalizeSelectionBounds(selection);
  return {
    ...normalized,
    minX: Math.min(normalized.startX, normalized.endX),
    maxX: Math.max(normalized.startX, normalized.endX),
  };
}

function isCellInPreparedSelection(
  x: number,
  y: number,
  selection: PreparedSelection
): boolean {
  const { startX, startY, endX, endY, isRectangle, minX, maxX } = selection;
  if (isRectangle) {
    // Rectangle selection: cell is in if x is between startX/endX
    // and y is between startY/endY
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
export function cellsRowToRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  y: number,
  selection?: SelectionBounds | PreparedSelection,
  hyperlinks?: HyperlinkTable,
  graphemes?: GraphemeTable,
  rowOffset?: number,
  rowRelativeTables: boolean = false,
  fontCoverage?: FontCoverageProfile
): StyledRun[] {
  const runs: StyledRun[] = [];
  let currentRun: StyledRun | null = null;
  const preparedSelection =
    selection === undefined
      ? undefined
      : "minX" in selection && "maxX" in selection
        ? selection
        : prepareSelection(selection);
  const baseOffset = rowOffset ?? y * cols;

  // Fast path: plain rows with no selection/link/grapheme metadata and no
  // fixed-width handling can be converted with minimal branching/allocation.
  if (!preparedSelection && !hyperlinks && !graphemes) {
    const fastRuns = tryBuildFastPathRuns(cells, styles, cols, baseOffset, fontCoverage);
    if (fastRuns) {
      return fastRuns;
    }
  }

  for (let x = 0; x < cols; x++) {
    const idx = baseOffset + x;
    const cell = cells[idx];
    const tableIndex = rowRelativeTables ? x : idx;

    // Skip spacer tails (second half of wide characters)
    // Spacer heads indicate a wrapped wide char on the next line and should
    // still occupy a cell to keep column alignment.
    if (cell && cell.wide === Wide.SPACER_TAIL) {
      continue;
    }

    const char = cell ? cellToChar(cell, graphemes, tableIndex) : " ";
    const styleId = cell?.styleId ?? 0;
    const selected = preparedSelection
      ? isCellInPreparedSelection(x, y, preparedSelection)
      : false;
    // Extract content-based bg color (for bg-only cells like htop headers)
    const bgOverride = cell ? getCellContentBgColor(cell) : undefined;
    // Get hyperlink URL if this cell is part of a hyperlink
    const hyperlink = (cell?.hyperlink && hyperlinks) ? hyperlinks.get(tableIndex) : undefined;

    const isWide = cell?.wide === Wide.WIDE;
    const isGrapheme = cell?.content.tag === ContentTag.CODEPOINT_GRAPHEME;
    const needsFallback = fontCoverage
      ? textNeedsFontFallback(char, fontCoverage)
      : false;
    const fixedWidth: 1 | 2 | undefined = isWide
      ? 2
      : isGrapheme || needsFallback
        ? 1
        : undefined;

    // Fixed-width glyphs remain discrete elements. This preserves the
    // server's logical cell occupancy while allowing the browser to select a
    // fallback face from the configured font stack.
    if (fixedWidth !== undefined) {
      const style = getStyle(styles, styleId);
      runs.push({
        text: char,
        cellCount: fixedWidth,
        fixedWidth,
        styleId,
        style,
        selected,
        bgOverride,
        hyperlink,
      });
      currentRun = null;
      continue;
    }

    // Start a new run if style, selection, bgOverride, or hyperlink changes
    if (
      currentRun &&
      currentRun.styleId === styleId &&
      currentRun.selected === selected &&
      colorsEqual(currentRun.bgOverride, bgOverride) &&
      currentRun.hyperlink === hyperlink
    ) {
      currentRun.text += char;
      currentRun.cellCount += 1;
    } else {
      const style = getStyle(styles, styleId);
      currentRun = {
        text: char,
        cellCount: 1,
        styleId,
        style,
        selected,
        bgOverride,
        hyperlink,
      };
      runs.push(currentRun);
    }
  }

  return runs;
}

export function cellsToRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  rows: number,
  selection?: SelectionBounds,
  hyperlinks?: HyperlinkTable,
  graphemes?: GraphemeTable,
  fontCoverage?: FontCoverageProfile
): StyledRun[][] {
  const lines: StyledRun[][] = [];
  const preparedSelection = prepareSelection(selection);

  for (let y = 0; y < rows; y++) {
    lines.push(
      cellsRowToRuns(
        cells,
        styles,
        cols,
        y,
        preparedSelection,
        hyperlinks,
        graphemes,
        undefined,
        false,
        fontCoverage
      )
    );
  }

  return lines;
}
