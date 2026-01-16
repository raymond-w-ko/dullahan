/**
 * Scrollback buffer management hook
 *
 * Maintains a history of terminal rows and viewport position.
 * Uses smart diffing with stable row IDs to detect:
 * - Scrolling: New lines at bottom, old lines pushed to history
 * - Full screen updates: Complete buffer replacement (vim, htop, etc.)
 */

import { useState, useCallback, useRef } from 'preact/hooks';
import type { Cell } from '../../../protocol/schema/cell';
import { ContentTag } from '../../../protocol/schema/cell';
import type { StyleTable } from '../../../protocol/schema/style';

export interface ScrollbackState {
  /** All rows in the buffer (history + active) */
  rows: Cell[][];
  /** Row IDs for each row (for diffing) */
  rowIds: bigint[];
  /** Style table (from most recent snapshot) */
  styles: StyleTable;
  /** Index of the first visible row in viewport */
  viewportTop: number;
  /** Number of visible rows */
  viewportRows: number;
  /** Number of columns per row */
  cols: number;
  /** Whether viewport is at the bottom (auto-scroll enabled) */
  isAtBottom: boolean;
  /** Total rows in buffer */
  totalRows: number;
  /** Whether currently showing alternate screen (vim, etc.) */
  altScreen: boolean;
}

export interface ScrollbackActions {
  /** Update with new snapshot data including row IDs for smart diffing */
  updateFromSnapshot: (
    cells: Cell[],
    styles: StyleTable,
    cols: number,
    rows: number,
    rowIds: bigint[],
    altScreen: boolean
  ) => void;
  /** Scroll viewport by delta rows (negative = up, positive = down) */
  scroll: (deltaRows: number) => void;
  /** Scroll to absolute position */
  scrollTo: (row: number) => void;
  /** Scroll to bottom (most recent) */
  scrollToBottom: () => void;
  /** Get the visible rows for rendering */
  getVisibleRows: () => Cell[][];
}

const DEFAULT_MAX_ROWS = 10000;

// Threshold for determining scroll vs full screen update
// If more than this fraction of rows have matching IDs, it's a scroll
const SCROLL_OVERLAP_THRESHOLD = 0.3;

/**
 * Detect scroll by comparing row IDs.
 * Returns the number of rows scrolled (positive = new lines at bottom)
 * or null if this looks like a full screen update.
 */
function detectScroll(
  prevRowIds: bigint[],
  newRowIds: bigint[]
): { scrollAmount: number; isScroll: boolean } {
  if (prevRowIds.length === 0 || newRowIds.length === 0) {
    return { scrollAmount: 0, isScroll: false };
  }

  // Create a set of previous row IDs for O(1) lookup
  const prevIdSet = new Set(prevRowIds.map(id => id.toString()));

  // Count how many new row IDs were in the previous set
  let matchCount = 0;
  let firstMatchNewIdx = -1;
  let firstMatchPrevIdx = -1;

  for (let i = 0; i < newRowIds.length; i++) {
    const idStr = newRowIds[i]!.toString();
    if (prevIdSet.has(idStr)) {
      matchCount++;
      if (firstMatchNewIdx === -1) {
        firstMatchNewIdx = i;
        // Find where this ID was in the previous set
        for (let j = 0; j < prevRowIds.length; j++) {
          if (prevRowIds[j]!.toString() === idStr) {
            firstMatchPrevIdx = j;
            break;
          }
        }
      }
    }
  }

  const overlapRatio = matchCount / Math.min(prevRowIds.length, newRowIds.length);

  // If overlap is below threshold, treat as full screen update
  if (overlapRatio < SCROLL_OVERLAP_THRESHOLD) {
    return { scrollAmount: 0, isScroll: false };
  }

  // Calculate scroll amount from position difference
  // Positive means rows scrolled up (new content at bottom)
  const scrollAmount = firstMatchPrevIdx - firstMatchNewIdx;

  return { scrollAmount, isScroll: true };
}

export function useScrollback(maxRows: number = DEFAULT_MAX_ROWS): [ScrollbackState, ScrollbackActions] {
  const [state, setState] = useState<ScrollbackState>({
    rows: [],
    rowIds: [],
    styles: new Map(),
    viewportTop: 0,
    viewportRows: 24,
    cols: 80,
    isAtBottom: true,
    totalRows: 0,
    altScreen: false,
  });

  // Track if we were at bottom before update
  const wasAtBottom = useRef(true);

  const updateFromSnapshot = useCallback((
    cells: Cell[],
    styles: StyleTable,
    cols: number,
    rows: number,
    rowIds: bigint[],
    altScreen: boolean
  ) => {
    setState(prev => {
      // Convert flat cells array to rows
      const newRows: Cell[][] = [];
      for (let y = 0; y < rows; y++) {
        const row: Cell[] = [];
        for (let x = 0; x < cols; x++) {
          const idx = y * cols + x;
          row.push(cells[idx] || {
            content: { tag: ContentTag.CODEPOINT, codepoint: 32 },
            styleId: 0,
            wide: 0,
            protected: false,
            hyperlink: false,
          });
        }
        newRows.push(row);
      }

      // Alt screen (vim, htop, etc.) always replaces buffer completely
      // and doesn't accumulate scrollback
      if (altScreen) {
        return {
          rows: newRows,
          rowIds: rowIds.slice(),
          styles,
          viewportTop: 0,
          viewportRows: rows,
          cols,
          isAtBottom: true,
          totalRows: newRows.length,
          altScreen: true,
        };
      }

      // If we were in alt screen and now we're not, restore normal mode
      // but start fresh (alt screen doesn't contribute to scrollback)
      if (prev.altScreen && !altScreen) {
        wasAtBottom.current = true;
        return {
          rows: newRows,
          rowIds: rowIds.slice(),
          styles,
          viewportTop: 0,
          viewportRows: rows,
          cols,
          isAtBottom: true,
          totalRows: newRows.length,
          altScreen: false,
        };
      }

      // Smart diffing: detect scroll vs full screen update
      const { scrollAmount, isScroll } = detectScroll(prev.rowIds, rowIds);

      let finalRows: Cell[][];
      let finalRowIds: bigint[];

      if (isScroll && scrollAmount > 0) {
        // Scroll detected - preserve history
        // Take rows that scrolled out of view and prepend them to buffer
        const scrolledOutRows = prev.rows.slice(0, scrollAmount);
        const scrolledOutIds = prev.rowIds.slice(0, scrollAmount);

        // Combine: scrolled out history + new screen content
        finalRows = [...scrolledOutRows, ...newRows];
        finalRowIds = [...scrolledOutIds, ...rowIds];

        // Trim to maxRows if needed (remove oldest)
        if (finalRows.length > maxRows) {
          const excess = finalRows.length - maxRows;
          finalRows = finalRows.slice(excess);
          finalRowIds = finalRowIds.slice(excess);
        }
      } else if (isScroll && scrollAmount < 0) {
        // Scrolled backwards (user scrolled up in terminal scrollback)
        // This is handled by the server's viewport, just update
        finalRows = newRows;
        finalRowIds = rowIds.slice();
      } else {
        // Full screen update or no scroll - replace buffer
        // This happens with clear screen, resize, or full-screen apps
        // that don't use alt screen
        finalRows = newRows;
        finalRowIds = rowIds.slice();
      }

      const totalRows = finalRows.length;

      // Calculate new viewport position
      let viewportTop = prev.viewportTop;
      if (prev.isAtBottom || wasAtBottom.current) {
        // Auto-scroll to bottom when at bottom
        viewportTop = Math.max(0, totalRows - rows);
      } else if (isScroll && scrollAmount > 0) {
        // Maintain relative position when scrolled up
        viewportTop = Math.min(prev.viewportTop + scrollAmount, Math.max(0, totalRows - rows));
      }

      wasAtBottom.current = viewportTop >= totalRows - rows;

      return {
        rows: finalRows,
        rowIds: finalRowIds,
        styles,
        viewportTop,
        viewportRows: rows,
        cols,
        isAtBottom: viewportTop >= totalRows - rows,
        totalRows,
        altScreen: false,
      };
    });
  }, [maxRows]);

  const scroll = useCallback((deltaRows: number) => {
    setState(prev => {
      const maxTop = Math.max(0, prev.totalRows - prev.viewportRows);
      const newTop = Math.max(0, Math.min(maxTop, prev.viewportTop + deltaRows));
      const isAtBottom = newTop >= maxTop;
      wasAtBottom.current = isAtBottom;
      
      return {
        ...prev,
        viewportTop: newTop,
        isAtBottom,
      };
    });
  }, []);

  const scrollTo = useCallback((row: number) => {
    setState(prev => {
      const maxTop = Math.max(0, prev.totalRows - prev.viewportRows);
      const newTop = Math.max(0, Math.min(maxTop, row));
      const isAtBottom = newTop >= maxTop;
      wasAtBottom.current = isAtBottom;
      
      return {
        ...prev,
        viewportTop: newTop,
        isAtBottom,
      };
    });
  }, []);

  const scrollToBottom = useCallback(() => {
    setState(prev => {
      const newTop = Math.max(0, prev.totalRows - prev.viewportRows);
      wasAtBottom.current = true;
      
      return {
        ...prev,
        viewportTop: newTop,
        isAtBottom: true,
      };
    });
  }, []);

  const getVisibleRows = useCallback((): Cell[][] => {
    const { rows, viewportTop, viewportRows } = state;
    return rows.slice(viewportTop, viewportTop + viewportRows);
  }, [state]);

  return [
    state,
    {
      updateFromSnapshot,
      scroll,
      scrollTo,
      scrollToBottom,
      getVisibleRows,
    },
  ];
}
