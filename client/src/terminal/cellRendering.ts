// Cell rendering utilities
// Converts terminal cells to styled text runs for rendering

import { cellToChar, ContentTag, Wide } from "../../../protocol/schema/cell";
import { getStyle, ColorTag } from "../../../protocol/schema/style";
import type { Cell, HyperlinkTable, GraphemeTable } from "../../../protocol/schema/cell";
import type { Style, StyleTable, Color } from "../../../protocol/schema/style";
import {
  normalizeSelectionBounds,
  type SelectionBounds,
} from "../../../protocol/schema/messages";

/** Range of a wide character within the run's text (start inclusive, end exclusive) */
export interface WideCharRange {
  start: number;
  end: number;
}

/** A run of consecutive cells with the same style */
export interface StyledRun {
  text: string;
  styleId: number;
  style: Style;
  selected?: boolean; // True if this run is within selection
  bgOverride?: Color; // Cell content-based bg color (BG_COLOR_PALETTE/RGB)
  hyperlink?: string; // URL for OSC 8 hyperlinks
  wideRanges?: WideCharRange[]; // Ranges of wide (2-cell) characters within text
  singleRanges?: WideCharRange[]; // Ranges of single-cell private-use characters within text
}

export interface PreparedSelection extends SelectionBounds {
  minX: number;
  maxX: number;
}

function isPrivateUseCodePoint(cp: number): boolean {
  // Private Use Areas:
  // - BMP:      U+E000..U+F8FF
  // - Plane 15: U+F0000..U+FFFFD
  // - Plane 16: U+100000..U+10FFFD
  return (
    (cp >= 0xe000 && cp <= 0xf8ff) ||
    (cp >= 0xf0000 && cp <= 0xffffd) ||
    (cp >= 0x100000 && cp <= 0x10fffd)
  );
}

function getCellCodepoint(cell: Cell | undefined): number {
  if (!cell) return 0;
  if (
    cell.content.tag === ContentTag.CODEPOINT ||
    cell.content.tag === ContentTag.CODEPOINT_GRAPHEME
  ) {
    return cell.content.codepoint;
  }
  return 0;
}

function isWhitespaceCodepoint(cp: number): boolean {
  return cp === 0 || cp === 0x0020 || cp === 0x2002;
}

function isPowerline(cp: number): boolean {
  return cp >= 0xe0b0 && cp <= 0xe0d7;
}

function isBoxDrawing(cp: number): boolean {
  return cp >= 0x2500 && cp <= 0x257f;
}

function isBlockElement(cp: number): boolean {
  return cp >= 0x2580 && cp <= 0x259f;
}

function isLegacyComputing(cp: number): boolean {
  return (cp >= 0x1fb00 && cp <= 0x1fbff) || (cp >= 0x1cc00 && cp <= 0x1cebf);
}

function isGraphicsElement(cp: number): boolean {
  return isBoxDrawing(cp) || isBlockElement(cp) || isLegacyComputing(cp) || isPowerline(cp);
}

function isSymbolLikeCodepoint(cp: number): boolean {
  return isPrivateUseCodePoint(cp);
}

const forcedSingleCodepoints = new Set<number>([
  0x279b,
]);

function isForcedSingleCodepoint(cp: number): boolean {
  return forcedSingleCodepoints.has(cp);
}

function isFastPathCell(cell: Cell | undefined): boolean {
  if (!cell) return true;
  if (cell.wide !== Wide.NARROW) return false;
  if (cell.hyperlink) return false;
  if (cell.content.tag !== ContentTag.CODEPOINT) return false;
  if (cell.content.codepoint === 0) return true;
  const cp = cell.content.codepoint;
  return !isSymbolLikeCodepoint(cp) && !isForcedSingleCodepoint(cp);
}

function tryBuildFastPathRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  baseOffset: number
): StyledRun[] | null {
  const runs: StyledRun[] = [];
  let currentRun: StyledRun | null = null;

  for (let x = 0; x < cols; x++) {
    const idx = baseOffset + x;
    const cell = cells[idx];
    if (!isFastPathCell(cell)) {
      return null;
    }
    const char = cell ? cellToChar(cell, undefined, idx) : " ";
    const styleId = cell?.styleId ?? 0;
    if (currentRun && currentRun.styleId === styleId) {
      currentRun.text += char;
      continue;
    }
    const style = getStyle(styles, styleId);
    currentRun = { text: char, styleId, style };
    runs.push(currentRun);
  }

  return runs;
}

function shouldExpandSymbol(
  cells: Cell[],
  idx: number,
  cols: number
): boolean {
  const cell = cells[idx];
  if (!cell) return false;
  if (cell.wide !== Wide.NARROW) return false;

  const cp = getCellCodepoint(cell);
  if (!isSymbolLikeCodepoint(cp)) return false;

  const x = idx % cols;
  if (x >= cols - 1) return false;

  const nextCell = cells[idx + 1];
  if (!nextCell || nextCell.wide !== Wide.NARROW) return false;
  const nextCp = getCellCodepoint(nextCell);
  if (!isWhitespaceCodepoint(nextCp)) return false;

  if (x > 0) {
    const prevCell = cells[idx - 1];
    const prevCp = getCellCodepoint(prevCell);
    if (isSymbolLikeCodepoint(prevCp) && !isGraphicsElement(prevCp)) {
      return false;
    }
  }

  return true;
}

function hasPrivateUse(text: string): boolean {
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    if (cp !== undefined && isPrivateUseCodePoint(cp)) {
      return true;
    }
  }
  return false;
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
  rowRelativeTables: boolean = false
): StyledRun[] {
  const runs: StyledRun[] = [];
  let currentRun: StyledRun | null = null;
  let skipNext = false;
  const preparedSelection =
    selection === undefined
      ? undefined
      : "minX" in selection && "maxX" in selection
        ? selection
        : prepareSelection(selection);
  const baseOffset = rowOffset ?? y * cols;

  // Fast path: plain rows with no selection/link/grapheme metadata and no
  // wide/symbol handling can be converted with minimal branching/allocation.
  if (!preparedSelection && !hyperlinks && !graphemes) {
    const fastRuns = tryBuildFastPathRuns(cells, styles, cols, baseOffset);
    if (fastRuns) {
      return fastRuns;
    }
  }

  for (let x = 0; x < cols; x++) {
    if (skipNext) {
      skipNext = false;
      continue;
    }
    const idx = baseOffset + x;
    const cell = cells[idx];
    const tableIndex = rowRelativeTables ? x : idx;

    // Skip spacer tails (second half of wide characters)
    // Spacer heads indicate a wrapped wide char on the next line and should
    // still occupy a cell to keep column alignment.
    if (cell && cell.wide === Wide.SPACER_TAIL) {
      continue;
    }

    const expandSymbol = shouldExpandSymbol(cells, idx, cols);
    if (expandSymbol) {
      skipNext = true;
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

    // Check if this is a wide character, or a private-use glyph that should
    // be constrained to a single cell (e.g. Nerd Font icons).
    const isWide = cell?.wide === Wide.WIDE || expandSymbol;
    const cp = getCellCodepoint(cell);
    const isPrivateUse = char.length > 0 && hasPrivateUse(char);
    const isSingle = !isWide && (isPrivateUse || isForcedSingleCodepoint(cp));

    // Start a new run if style, selection, bgOverride, or hyperlink changes
    if (
      currentRun &&
      currentRun.styleId === styleId &&
      currentRun.selected === selected &&
      colorsEqual(currentRun.bgOverride, bgOverride) &&
      currentRun.hyperlink === hyperlink
    ) {
      if (isWide) {
        // Track the range of this wide character (graphemes can be multi-codepoint)
        if (!currentRun.wideRanges) {
          currentRun.wideRanges = [];
        }
        const start = currentRun.text.length;
        currentRun.text += char;
        currentRun.wideRanges.push({ start, end: currentRun.text.length });
      } else if (isSingle) {
        if (!currentRun.singleRanges) {
          currentRun.singleRanges = [];
        }
        const start = currentRun.text.length;
        currentRun.text += char;
        currentRun.singleRanges.push({ start, end: currentRun.text.length });
      } else {
        currentRun.text += char;
      }
    } else {
      const style = getStyle(styles, styleId);
      currentRun = { text: char, styleId, style, selected, bgOverride, hyperlink };
      if (isWide) {
        currentRun.wideRanges = [{ start: 0, end: char.length }];
      } else if (isSingle) {
        currentRun.singleRanges = [{ start: 0, end: char.length }];
      }
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
  graphemes?: GraphemeTable
): StyledRun[][] {
  const lines: StyledRun[][] = [];
  const preparedSelection = prepareSelection(selection);

  for (let y = 0; y < rows; y++) {
    lines.push(cellsRowToRuns(cells, styles, cols, y, preparedSelection, hyperlinks, graphemes));
  }

  return lines;
}
