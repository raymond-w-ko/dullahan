/**
 * Scrollback buffer management hook
 * 
 * Maintains a history of terminal rows and viewport position.
 * New output appends to history (up to maxRows).
 * Viewport can scroll through the buffer.
 */

import { useState, useCallback, useRef, useEffect } from 'preact/hooks';
import type { Cell } from '../../../protocol/schema/cell';
import { ContentTag } from '../../../protocol/schema/cell';
import type { StyleTable } from '../../../protocol/schema/style';

export interface ScrollbackState {
  /** All rows in the buffer (history + active) */
  rows: Cell[][];
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
}

export interface ScrollbackActions {
  /** Update with new snapshot data */
  updateFromSnapshot: (
    cells: Cell[],
    styles: StyleTable,
    cols: number,
    rows: number
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

export function useScrollback(maxRows: number = DEFAULT_MAX_ROWS): [ScrollbackState, ScrollbackActions] {
  const [state, setState] = useState<ScrollbackState>({
    rows: [],
    styles: new Map(),
    viewportTop: 0,
    viewportRows: 24,
    cols: 80,
    isAtBottom: true,
    totalRows: 0,
  });

  // Track if we were at bottom before update
  const wasAtBottom = useRef(true);

  const updateFromSnapshot = useCallback((
    cells: Cell[],
    styles: StyleTable,
    cols: number,
    rows: number
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

      // For now, just replace entirely
      // TODO: Implement smart diffing to detect scrollback vs. screen updates
      // This is a simplistic approach - full screen updates replace buffer
      const totalRows = newRows.length;
      
      // Calculate new viewport position
      let viewportTop = prev.viewportTop;
      if (prev.isAtBottom || wasAtBottom.current) {
        // Auto-scroll to bottom
        viewportTop = Math.max(0, totalRows - rows);
      }

      wasAtBottom.current = viewportTop >= totalRows - rows;

      return {
        rows: newRows,
        styles,
        viewportTop,
        viewportRows: rows,
        cols,
        isAtBottom: viewportTop >= totalRows - rows,
        totalRows,
      };
    });
  }, []);

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
