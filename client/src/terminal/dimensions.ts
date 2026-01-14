/**
 * Shared terminal cell dimension calculation utilities.
 *
 * Provides consistent cell measurement across:
 * - connection.ts (for resize calculations)
 * - mouse.ts (for click coordinate conversion)
 * - useTerminalDimensions.ts (for React state)
 */

export interface CellDimensions {
  cellWidth: number;
  cellHeight: number;
}

export interface Padding {
  left: number;
  right: number;
  top: number;
  bottom: number;
  horizontal: number;
  vertical: number;
}

export interface TerminalSize {
  cols: number;
  rows: number;
  cellWidth: number;
  cellHeight: number;
}

/**
 * Find or create the measurement element used for cell dimension calculation.
 * The element is a single character 'X' styled with terminal font.
 */
export function getOrCreateMeasureElement(
  container: HTMLElement
): HTMLDivElement {
  let measure = container.querySelector(
    ".terminal-measure"
  ) as HTMLDivElement | null;
  if (!measure) {
    measure = document.createElement("div");
    measure.className = "terminal-measure terminal-line";
    measure.textContent = "X";
    container.appendChild(measure);
  }
  return measure;
}

/**
 * Get cell dimensions from a measurement element.
 * Returns { cellWidth: 0, cellHeight: 0 } if element has no size.
 */
export function getCellDimensions(measureElement: HTMLElement): CellDimensions {
  const rect = measureElement.getBoundingClientRect();
  return {
    cellWidth: rect.width,
    cellHeight: rect.height,
  };
}

/**
 * Get padding values from an element's computed style.
 */
export function getPadding(element: HTMLElement): Padding {
  const style = getComputedStyle(element);
  const left = parseFloat(style.paddingLeft);
  const right = parseFloat(style.paddingRight);
  const top = parseFloat(style.paddingTop);
  const bottom = parseFloat(style.paddingBottom);
  return {
    left,
    right,
    top,
    bottom,
    horizontal: left + right,
    vertical: top + bottom,
  };
}

/**
 * Safe minimum cell dimensions to prevent division by zero or tiny cells.
 */
export const MIN_CELL_WIDTH = 4;
export const MIN_CELL_HEIGHT = 8;

/**
 * Maximum terminal dimensions (cols/rows).
 */
export const MAX_TERMINAL_SIZE = 500;

/**
 * Calculate terminal size (cols/rows) from a container element.
 * Accounts for both container padding and nested .terminal element padding.
 *
 * @returns Terminal size, or { cols: -1, rows: -1 } if not ready to measure
 */
export function calculateTerminalSize(container: HTMLElement): TerminalSize {
  const measure = getOrCreateMeasureElement(container);
  const { cellWidth, cellHeight } = getCellDimensions(measure);

  // Not ready if we can't measure
  if (cellWidth === 0 || cellHeight === 0) {
    return { cols: -1, rows: -1, cellWidth: 0, cellHeight: 0 };
  }

  // Get container padding
  const containerPadding = getPadding(container);

  // Also account for .terminal element padding inside the container
  const terminal = container.querySelector(".terminal") as HTMLElement | null;
  let terminalPaddingX = 0;
  let terminalPaddingY = 0;
  if (terminal) {
    const terminalPadding = getPadding(terminal);
    terminalPaddingX = terminalPadding.horizontal;
    terminalPaddingY = terminalPadding.vertical;
  }

  const availableWidth =
    container.clientWidth - containerPadding.horizontal - terminalPaddingX;
  const availableHeight =
    container.clientHeight - containerPadding.vertical - terminalPaddingY;

  // Not ready if container has no size
  if (availableWidth <= 0 || availableHeight <= 0) {
    return { cols: -1, rows: -1, cellWidth, cellHeight };
  }

  // Calculate dimensions with safe minimums
  const safeCellWidth = Math.max(cellWidth, MIN_CELL_WIDTH);
  const safeCellHeight = Math.max(cellHeight, MIN_CELL_HEIGHT);

  const cols = Math.floor(availableWidth / safeCellWidth);
  const rows = Math.floor(availableHeight / safeCellHeight);

  // Clamp to reasonable terminal sizes
  return {
    cols: Math.max(1, Math.min(MAX_TERMINAL_SIZE, cols)),
    rows: Math.max(1, Math.min(MAX_TERMINAL_SIZE, rows)),
    cellWidth,
    cellHeight,
  };
}
