// Terminal rendering component
// Displays terminal cells with styling and cursor

import { h } from "preact";
import { debug } from "../debug";
import { useRef, useEffect, useCallback } from "preact/hooks";
import { TerminalConnection } from "../terminal/connection";
import { KeyboardHandler, createKeyboardHandler } from "../terminal/keyboard";
import { IMEHandler, createIMEHandler } from "../terminal/ime";
import { MouseHandler, createMouseHandler } from "../terminal/mouse";
import { getActiveKeybinds, onKeybindsChange } from "../terminal/keybindConfig";
import {
  getSelection as getDOMSelection,
  copyToClipboard,
  pasteFromClipboard,
  clearSelection,
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
  getMostRecentClipboard,
  setClipboardC,
} from "../store";
import { cellsToRuns } from "../terminal/cellRendering";
import { renderLine } from "../terminal/cursorRendering";
import { SCROLL } from "../constants";
import type { CursorConfig } from "../terminal/cursorRendering";
import type { TerminalSnapshot } from "../terminal/connection";

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
}: TerminalViewProps) {
  const { cols, rows, cursor, cells, styles } = snapshot;
  const terminalRef = useRef<HTMLPreElement>(null);
  const keyboardRef = useRef<KeyboardHandler | null>(null);
  const imeRef = useRef<IMEHandler | null>(null);
  const mouseRef = useRef<MouseHandler | null>(null);

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
      debug.error("IME failed to create input element");
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
        // Use most recent internal clipboard if available
        const recent = getMostRecentClipboard();
        if (recent) {
          return recent.text;
        }
        // Fall back to system clipboard
        return pasteFromClipboard();
      },
      writeClipboard: async (text: string) => {
        await copyToClipboard(text);
        // Also update internal clipboard so ClipboardBar shows it
        setClipboardC(text);
        // Clear selection after copy if configured
        if (config.get("selectionClearOnCopy")) {
          clearSelection();
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

    // Update cell dimensions when fonts load
    document.fonts.ready.then(() => {
      mouse.updateCellDimensions();
    });

    return () => {
      mouse.detach();
    };
  }, [paneId, connection]);

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

  // Convert cells to styled runs (with selection highlighting, hyperlinks, and graphemes if active)
  const lines = cellsToRuns(cells, styles, cols, rows, snapshot.selection, snapshot.hyperlinks, snapshot.graphemes);

  // Build cursor config object
  const cursorConfig: CursorConfig = {
    style: cursorStyle,
    color: cursorColor,
    textColor: cursorText,
    blink: cursorBlink,
  };

  // Show scrollback indicator if not at bottom
  const isScrolledUp =
    snapshot.scrollback.viewportTop < snapshot.scrollback.totalRows - rows;

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
      {lines.map((runs, y) => (
        <div key={y} class="terminal-line">
          {renderLine(runs, y, cursor, cursorConfig, isActive)}
        </div>
      ))}
    </pre>
  );
}
