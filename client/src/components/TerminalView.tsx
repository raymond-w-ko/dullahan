// Terminal rendering component
// Displays terminal cells with styling and cursor

import { h } from "preact";
import { memo } from "preact/compat";
import { debug } from "../debug";

const imeLog = debug.category('ime');
const clipboardLog = debug.category('clipboard');
import { useRef, useEffect, useCallback, useMemo } from "preact/hooks";
import { TerminalConnection } from "../terminal/connection";
import { KeyboardHandler, createKeyboardHandler } from "../terminal/keyboard";
import { IMEHandler, createIMEHandler } from "../terminal/ime";
import { MouseHandler, createMouseHandler } from "../terminal/mouse";
import { getActiveKeybinds, onKeybindsChange } from "../terminal/keybindConfig";
import {
  getSelection as getDOMSelection,
  copyToClipboard,
  pasteFromClipboard,
  readImageFromClipboard,
  getTerminalSelectionText,
} from "../terminal/clipboard";
import type { ActionContext } from "../terminal/actions";
import * as config from "../config";
import {
  getStore,
  setSettingsOpen,
  switchWindow,
  createWindow,
  closeWindow,
  setFocusedPane,
  toggleFullscreen,
} from "../store";
import {
  cellsRowToRuns,
  type PreparedSelection,
  prepareSelection,
  type StyledRun,
} from "../terminal/cellRendering";
import { renderLine } from "../terminal/cursorRendering";
import { SCROLL } from "../constants";
import type { CursorConfig, CursorState } from "../terminal/cursorRendering";
import type { TerminalSnapshot } from "../terminal/connection";
import type { SelectionBounds } from "../../../protocol/schema/messages";

const MAX_IMAGE_PASTE_BYTES = 32 * 1024 * 1024;
const INVALID_ROW_ID = 0xffffffffffffffffn;
const MAX_CACHED_ROW_RUNS = 800;

interface RowRunsCacheEntry {
  runs: StyledRun[];
  selectionKey: string;
  cols: number;
  lastAccess: number;
}

interface RowRunsEvictionCandidate {
  rowId: bigint;
  lastAccess: number;
}

function heapSiftUpByLastAccess(heap: RowRunsEvictionCandidate[], index: number): void {
  let i = index;
  while (i > 0) {
    const parent = (i - 1) >> 1;
    if (heap[parent]!.lastAccess >= heap[i]!.lastAccess) {
      break;
    }
    const tmp = heap[parent]!;
    heap[parent] = heap[i]!;
    heap[i] = tmp;
    i = parent;
  }
}

function heapSiftDownByLastAccess(heap: RowRunsEvictionCandidate[], index: number): void {
  let i = index;
  const n = heap.length;
  while (true) {
    const left = i * 2 + 1;
    const right = left + 1;
    let largest = i;

    if (left < n && heap[left]!.lastAccess > heap[largest]!.lastAccess) {
      largest = left;
    }
    if (right < n && heap[right]!.lastAccess > heap[largest]!.lastAccess) {
      largest = right;
    }
    if (largest === i) {
      break;
    }
    const tmp = heap[largest]!;
    heap[largest] = heap[i]!;
    heap[i] = tmp;
    i = largest;
  }
}

function pushOldestRowRunsCandidate(
  heap: RowRunsEvictionCandidate[],
  candidate: RowRunsEvictionCandidate,
  maxSize: number
): void {
  if (maxSize <= 0) {
    return;
  }
  if (heap.length < maxSize) {
    heap.push(candidate);
    heapSiftUpByLastAccess(heap, heap.length - 1);
    return;
  }
  if (candidate.lastAccess >= heap[0]!.lastAccess) {
    return;
  }
  heap[0] = candidate;
  heapSiftDownByLastAccess(heap, 0);
}

function getRowSelectionKey(
  y: number,
  cols: number,
  selection: PreparedSelection | undefined
): string {
  if (!selection) {
    return "n";
  }
  const { startX, startY, endX, endY, isRectangle, minX, maxX } = selection;
  if (y < startY || y > endY) {
    return "n";
  }
  if (isRectangle) {
    return `r:${minX}:${maxX}`;
  }
  if (startY === endY) {
    return `l:${startX}:${endX}`;
  }
  if (y === startY) {
    return `l:${startX}:${cols - 1}`;
  }
  if (y === endY) {
    return `l:0:${endX}`;
  }
  return `l:0:${cols - 1}`;
}

const HIDDEN_CURSOR: CursorState = {
  x: 0,
  y: -1,
  visible: false,
  blink: true,
};

interface TerminalRowProps {
  runs: StyledRun[];
  y: number;
  cols: number;
  showCursor: boolean;
  cursorX: number;
  cursorBlinkFromServer: boolean;
  cursorStyle: "block" | "bar" | "underline" | "block_hollow";
  cursorColor: string;
  cursorText: string;
  cursorBlink: "" | "true" | "false";
}

const TerminalRow = memo(function TerminalRow({
  runs,
  y,
  cols,
  showCursor,
  cursorX,
  cursorBlinkFromServer,
  cursorStyle,
  cursorColor,
  cursorText,
  cursorBlink,
}: TerminalRowProps) {
  const rowCursor: CursorState = showCursor
    ? {
        x: cursorX,
        y,
        visible: true,
        blink: cursorBlinkFromServer,
      }
    : HIDDEN_CURSOR;

  const rowCursorConfig: CursorConfig = {
    style: cursorStyle,
    color: cursorColor,
    textColor: cursorText,
    blink: cursorBlink,
  };

  return (
    <div class="terminal-line">
      {renderLine(runs, y, rowCursor, rowCursorConfig, true, cols)}
    </div>
  );
}, (prev, next) => {
  if (
    prev.runs !== next.runs ||
    prev.y !== next.y ||
    prev.cols !== next.cols ||
    prev.showCursor !== next.showCursor
  ) {
    return false;
  }

  // Cursor-related props only matter on the row that currently renders cursor.
  if (!next.showCursor) {
    return true;
  }

  return (
    prev.cursorX === next.cursorX &&
    prev.cursorBlinkFromServer === next.cursorBlinkFromServer &&
    prev.cursorStyle === next.cursorStyle &&
    prev.cursorColor === next.cursorColor &&
    prev.cursorText === next.cursorText &&
    prev.cursorBlink === next.cursorBlink
  );
});

export interface TerminalViewProps {
  paneId: number;
  snapshot: TerminalSnapshot;
  cursorStyle: "block" | "bar" | "underline" | "block_hollow";
  cursorColor: string;
  cursorText: string;
  cursorBlink: "" | "true" | "false";
  isReadOnly: boolean;
  isActive: boolean;
  onKeyInput?: () => void;
  connection: TerminalConnection | null;
  theme: string;
  deltaChangedRowIds: bigint[];
  deltaGen: number;
}

export function TerminalView({
  paneId,
  snapshot,
  cursorStyle,
  cursorColor,
  cursorText,
  cursorBlink,
  isReadOnly,
  isActive,
  onKeyInput,
  connection,
  theme,
  deltaChangedRowIds,
  deltaGen,
}: TerminalViewProps) {
  const { cols, rows, cursor, styles } = snapshot;
  const terminalRef = useRef<HTMLPreElement>(null);
  const keyboardRef = useRef<KeyboardHandler | null>(null);
  const imeRef = useRef<IMEHandler | null>(null);
  const mouseRef = useRef<MouseHandler | null>(null);
  const rowRunsCacheRef = useRef<Map<bigint, RowRunsCacheEntry>>(new Map());
  const rowRunsClockRef = useRef(0);
  const lastRenderedGenRef = useRef<number | null>(null);
  const lastAppliedDeltaInvalidationGenRef = useRef<number | null>(null);
  const cacheContextRef = useRef({
    paneId,
    cols,
    altScreen: snapshot.altScreen,
    theme,
  });

  // Keep current snapshot in a ref so getSelection closure always accesses latest
  const snapshotRef = useRef(snapshot);
  snapshotRef.current = snapshot;

  // Setup keyboard and IME handlers
  useEffect(() => {
    if (!terminalRef.current || isReadOnly) return;

    const keyboard = createKeyboardHandler();
    const ime = createIMEHandler();
    keyboardRef.current = keyboard;
    imeRef.current = ime;

    // Attach IME first - creates hidden textarea for composition input
    ime.attach(terminalRef.current, (msg) => {
      if (connection?.isConnected) {
        connection.sendText(msg);
      }
      onKeyInput?.();
    });
    ime.setPaneId(paneId);
    keyboard.setPaneId(paneId);

    // Get the textarea element created by IME for keyboard attachment
    // KeyboardHandler must attach to the same element for focus to work
    const inputElement = ime.getElement();
    if (!inputElement) {
      imeLog.error("IME failed to create input element");
      return;
    }

    // Create action context for keybind execution
    const actionContext: ActionContext = {
      paneId,
      sendText: (text: string) => {
        if (connection?.isConnected) {
          connection.sendText({
            type: "text",
            paneId,
            data: text,
            timestamp: performance.now(),
          });
        }
      },
      sendScroll: (targetPaneId: number, lines: number) => {
        if (connection?.isConnected) {
          connection.sendScroll(targetPaneId, lines);
        }
      },
      getSelection: () => {
        // First check for terminal selection (from server)
        // Use ref to always get current snapshot (avoids stale closure)
        const currentSnapshot = snapshotRef.current;
        if (currentSnapshot.selection) {
          return getTerminalSelectionText(
            currentSnapshot.cells,
            currentSnapshot.cols,
            currentSnapshot.selection,
            currentSnapshot.graphemes
          );
        }
        // Fall back to DOM selection
        return getDOMSelection();
      },
      readClipboard: async () => {
        // Always read from navigator.clipboard for keybind paste
        // This matches standard terminal emulator behavior
        return pasteFromClipboard();
      },
      pasteImageFromClipboard: async () => {
        if (!connection?.isConnected || !connection.isMaster) return false;

        const image = await readImageFromClipboard();
        if (!image) return false;

        if (image.size > MAX_IMAGE_PASTE_BYTES) {
          window.alert(`Paste failed: image is ${image.size} bytes, limit is ${MAX_IMAGE_PASTE_BYTES} bytes.`);
          return true;
        }

        const headers: Record<string, string> = {
          "Content-Type": image.mime,
        };
        if (connection.authToken) {
          headers.Authorization = `Bearer ${connection.authToken}`;
        }

        try {
          const response = await fetch("/api/paste-image", {
            method: "POST",
            headers,
            body: image.blob,
          });

          if (!response.ok) {
            window.alert(`Paste failed: upload rejected (${response.status}).`);
            return true;
          }

          const uploadedPath = response.headers.get("x-dullahan-image-path");
          if (!uploadedPath) {
            window.alert("Paste failed: server did not return an uploaded path.");
            return true;
          }

          connection.sendImagePaste(paneId, uploadedPath);
          clipboardLog.log(`Image pasted as path: pane=${paneId} bytes=${image.size} mime=${image.mime}`);
          return true;
        } catch (err) {
          clipboardLog.warn("Image upload paste failed:", err);
          window.alert(`Paste failed: ${err instanceof Error ? err.message : "Upload failed"}`);
          return true;
        }
      },
      writeClipboard: async (text: string) => {
        await copyToClipboard(text);
      },
      sendCopy: (targetPaneId: number) => {
        if (connection?.isConnected) {
          connection.sendCopy(targetPaneId);
          // Clear server-side selection after copy if configured
          if (config.get("selectionClearOnCopy")) {
            connection.clearSelection(targetPaneId);
          }
        }
      },
      switchWindow: (windowId: number) => switchWindow(windowId),
      getWindowIds: () => {
        const store = getStore();
        return Array.from(store.windows.keys()).sort((a, b) => a - b);
      },
      getActiveWindowId: () => getStore().activeWindowId,
      createWindow: () => createWindow(),
      closeWindow: (windowId: number) => closeWindow(windowId),
      openSettings: () => setSettingsOpen(true),
      setFocusedPane: (targetPaneId: number) => setFocusedPane(targetPaneId),
      getPaneIds: () => {
        const store = getStore();
        const activeWindow = store.windows.get(store.activeWindowId);
        return activeWindow?.paneIds ?? [];
      },
      getFocusedPaneId: () => getStore().focusedPaneId,
      toggleFullscreen: (targetPaneId: number) => toggleFullscreen(targetPaneId),
      selectAll: (targetPaneId: number) => {
        if (connection?.isConnected) {
          connection.selectAll(targetPaneId);
        }
      },
      clearSelectionInPane: (targetPaneId: number) => {
        if (connection?.isConnected) {
          connection.clearSelection(targetPaneId);
        }
      },
    };

    // Set up keybinds
    keyboard.setKeybinds(getActiveKeybinds());
    keyboard.setActionContext(actionContext);

    // Listen for keybind config changes
    const unsubscribeKeybinds = onKeybindsChange((keybinds) => {
      keyboard.setKeybinds(keybinds);
    });

    // Attach keyboard to IME's textarea element
    keyboard.attach(inputElement, (msg) => {
      if (connection?.isConnected) {
        connection.sendKey(msg);
      }
      // Dismiss bell on keydown, ignoring modifier-only keys
      const isModifierOnly = ["Shift", "Control", "Alt", "Meta"].includes(
        msg.key
      );
      if (msg.state === "down" && !isModifierOnly) {
        onKeyInput?.();
      }
    });

    // Attach global copy handler for when terminal has selection but IME isn't focused
    if (terminalRef.current) {
      keyboard.attachGlobalCopyHandler(terminalRef.current);
    }

    // Auto-focus terminal on mount (focus IME's textarea)
    ime.focus();

    return () => {
      keyboard.detach();
      ime.detach();
      unsubscribeKeybinds();
    };
  }, [connection, isReadOnly, onKeyInput, paneId]);

  // Handle wheel events for scrollback
  const handleWheel = useCallback(
    (e: WheelEvent) => {
      e.preventDefault();
      if (!connection?.isConnected) return;

      // Convert wheel delta to rows
      const delta = Math.sign(e.deltaY) * SCROLL.ROWS_PER_TICK;
      connection.sendScroll(paneId, delta);
    },
    [connection, paneId]
  );

  // Attach wheel handler (even for read-only panes - they can still scroll)
  useEffect(() => {
    const el = terminalRef.current;
    if (!el) return;

    el.addEventListener("wheel", handleWheel, { passive: false });
    return () => el.removeEventListener("wheel", handleWheel);
  }, [handleWheel]);

  // When this pane becomes active (e.g., from window switch), focus IME and notify server
  useEffect(() => {
    if (isActive && !isReadOnly) {
      // Focus the IME for keyboard input
      imeRef.current?.focus();
      // Notify server of focus change
      if (connection?.isConnected) {
        connection.sendFocus(paneId);
      }
    }
  }, [isActive, isReadOnly, connection, paneId]);

  // Setup mouse handler
  useEffect(() => {
    const el = terminalRef.current;
    if (!el) return;

    const mouse = createMouseHandler();
    mouseRef.current = mouse;
    mouse.setPaneId(paneId);

    // Attach to terminal element
    mouse.attach(el, (msg) => {
      if (connection?.isConnected) {
        connection.sendMouse(msg);
      }
    });

    // Set focus target to IME textarea so keyboard input works after mouse selection
    const imeElement = imeRef.current?.getElement();
    if (imeElement) {
      mouse.setFocusTarget(imeElement);
    }

    // Use a stable lookup closure that always reads from the latest snapshot ref.
    mouse.setHyperlinkLookup((x: number, y: number) => {
      const currentSnapshot = snapshotRef.current;
      const row = currentSnapshot.viewportRows?.[y];
      if (row) {
        return row.hyperlinks?.get(x);
      }
      if (currentSnapshot.viewportRows) {
        return undefined;
      }
      const idx = y * currentSnapshot.cols + x;
      return currentSnapshot.hyperlinks.get(idx);
    });

    // Update cell dimensions when fonts load
    document.fonts.ready.then(() => {
      mouse.updateCellDimensions();
    });

    return () => {
      mouse.setHyperlinkLookup(null);
      mouse.detach();
      if (mouseRef.current === mouse) {
        mouseRef.current = null;
      }
    };
  }, [paneId, connection]);

  // Measure cell width and keep CSS variable in sync with font changes
  useEffect(() => {
    const el = terminalRef.current;
    if (!el) return;

    const container = el.parentElement;
    if (!container) return;

    let rafId: number | null = null;

    const updateCellWidth = () => {
      let measure = container.querySelector(".terminal-measure") as HTMLDivElement | null;
      if (!measure) {
        measure = document.createElement("div");
        measure.className = "terminal-measure terminal-line";
        measure.textContent = "X";
        container.appendChild(measure);
      }

      const rect = measure.getBoundingClientRect();
      if (rect.width > 0) {
        el.style.setProperty("--cell-width", `${rect.width}px`);
      }
    };

    const scheduleUpdateCellWidth = () => {
      if (rafId !== null) {
        cancelAnimationFrame(rafId);
      }
      rafId = requestAnimationFrame(() => {
        rafId = null;
        updateCellWidth();
      });
    };

    const measure = container.querySelector(".terminal-measure") as HTMLDivElement | null;
    const observedMeasure =
      measure ??
      (() => {
        const created = document.createElement("div");
        created.className = "terminal-measure terminal-line";
        created.textContent = "X";
        container.appendChild(created);
        return created;
      })();

    // Initial measurement + re-measure when browser font loading settles
    scheduleUpdateCellWidth();
    document.fonts.ready.then(scheduleUpdateCellWidth);

    // Keep width synced when font settings change and resize the measure element.
    const observer = new ResizeObserver(() => {
      scheduleUpdateCellWidth();
    });
    observer.observe(observedMeasure);

    return () => {
      if (rafId !== null) {
        cancelAnimationFrame(rafId);
      }
      observer.disconnect();
    };
  }, []);

  // Focus IME textarea when terminal is clicked (but not when selecting text)
  // The keyboard handler is attached to the IME textarea, not the terminal element
  const handleTerminalClick = useCallback(() => {
    // Don't steal focus if user is selecting text - this would clear the selection
    const selection = window.getSelection();
    if (selection && selection.toString().length > 0) {
      return;
    }
    imeRef.current?.focus();
  }, []);

  // Convert cells to runs with per-row caching keyed by stable row IDs.
  const lines = useMemo(() => {
    const cache = rowRunsCacheRef.current;
    const context = cacheContextRef.current;
    if (
      context.paneId !== paneId ||
      context.cols !== cols ||
      context.altScreen !== snapshot.altScreen ||
      context.theme !== theme
    ) {
      cache.clear();
      cacheContextRef.current = {
        paneId,
        cols,
        altScreen: snapshot.altScreen,
        theme,
      };
    }

    // If generation changed and we don't yet have matching dirty row metadata
    // for this generation, clear cache to avoid stale row reuse.
    if (lastRenderedGenRef.current !== snapshot.gen && deltaGen !== snapshot.gen) {
      cache.clear();
      lastAppliedDeltaInvalidationGenRef.current = null;
    }

    if (
      deltaGen === snapshot.gen &&
      lastAppliedDeltaInvalidationGenRef.current !== snapshot.gen
    ) {
      for (const changedRowId of deltaChangedRowIds) {
        cache.delete(changedRowId);
      }
      lastAppliedDeltaInvalidationGenRef.current = snapshot.gen;
    }

    const selection = snapshot.selection;
    const preparedSelection = prepareSelection(selection);

    const nextLines: StyledRun[][] = new Array(rows);
    for (let y = 0; y < rows; y++) {
      const rowId = snapshot.rowIds[y];
      const selectionKey = getRowSelectionKey(y, cols, preparedSelection);
      let runs: StyledRun[] | undefined;

      if (rowId !== undefined && rowId !== INVALID_ROW_ID) {
        const cached = cache.get(rowId);
        if (cached && cached.cols === cols && cached.selectionKey === selectionKey) {
          cached.lastAccess = ++rowRunsClockRef.current;
          runs = cached.runs;
        }
      }

      if (!runs) {
        const rowView = snapshot.viewportRows?.[y];
        if (rowView) {
          runs = cellsRowToRuns(
            rowView.cells,
            styles,
            cols,
            y,
            preparedSelection,
            rowView.hyperlinks,
            rowView.graphemes,
            rowView.offset,
            true
          );
        } else if (snapshot.viewportRows) {
          runs = cellsRowToRuns([], styles, cols, y, preparedSelection);
        } else {
          runs = cellsRowToRuns(
            snapshot.cells,
            styles,
            cols,
            y,
            preparedSelection,
            snapshot.hyperlinks,
            snapshot.graphemes
          );
        }

        if (rowId !== undefined && rowId !== INVALID_ROW_ID) {
          cache.set(rowId, {
            runs,
            cols,
            selectionKey,
            lastAccess: ++rowRunsClockRef.current,
          });
        }
      }

      nextLines[y] = runs;
    }

    if (cache.size > MAX_CACHED_ROW_RUNS) {
      const overflow = cache.size - MAX_CACHED_ROW_RUNS;
      const oldestCandidates: RowRunsEvictionCandidate[] = [];
      for (const [rowId, entry] of cache.entries()) {
        pushOldestRowRunsCandidate(
          oldestCandidates,
          { rowId, lastAccess: entry.lastAccess },
          overflow
        );
      }
      for (const candidate of oldestCandidates) {
        cache.delete(candidate.rowId);
      }
    }

    lastRenderedGenRef.current = snapshot.gen;

    return nextLines;
  }, [
    paneId,
    styles,
    cols,
    rows,
    snapshot.altScreen,
    snapshot.rowIds,
    snapshot.viewportRows,
    snapshot.selection,
    theme,
    deltaChangedRowIds,
    deltaGen,
    snapshot.gen,
  ]);

  // Show scrollback indicator if not at bottom
  const isScrolledUp =
    snapshot.scrollback.viewportTop < snapshot.scrollback.totalRows - rows;
  const hasVisibleCursor = isActive && cursor.visible;

  return (
    <pre
      class="terminal"
      ref={terminalRef}
      onClick={handleTerminalClick}
    >
      {isScrolledUp && (
        <div class="scrollback-indicator">
          {snapshot.scrollback.totalRows - snapshot.scrollback.viewportTop - rows} lines above
        </div>
      )}
      {lines.map((runs, y) => {
        const rowId = snapshot.rowIds[y];
        const key = rowId !== undefined && rowId !== INVALID_ROW_ID
          ? `row-${rowId.toString()}`
          : `row-invalid-${y}`;
        const showCursor = hasVisibleCursor && cursor.y === y;
        return (
          <TerminalRow
            key={key}
            runs={runs}
            y={y}
            cols={cols}
            showCursor={showCursor}
            cursorX={cursor.x}
            cursorBlinkFromServer={cursor.blink}
            cursorStyle={cursorStyle}
            cursorColor={cursorColor}
            cursorText={cursorText}
            cursorBlink={cursorBlink}
          />
        );
      })}
    </pre>
  );
}
