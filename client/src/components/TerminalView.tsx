// Terminal rendering component
// Displays terminal cells with styling and cursor

import { h } from "preact";
import { useRef, useEffect, useCallback } from "preact/hooks";
import { TerminalConnection } from "../terminal/connection";
import { KeyboardHandler, createKeyboardHandler } from "../terminal/keyboard";
import { IMEHandler, createIMEHandler } from "../terminal/ime";
import { getActiveKeybinds, onKeybindsChange } from "../terminal/keybindConfig";
import {
  getSelection,
  copyToClipboard,
  pasteFromClipboard,
  clearSelection,
} from "../terminal/clipboard";
import type { ActionContext } from "../terminal/actions";
import * as config from "../config";
import {
  getStore,
  setSettingsOpen,
  switchWindow,
  createWindow,
  setFocusedPane,
} from "../store";
import { cellToChar } from "../../../protocol/schema/cell";
import { getStyle, ColorTag, Underline } from "../../../protocol/schema/style";
import type { TerminalSnapshot } from "../terminal/connection";
import type { Cell } from "../../../protocol/schema/cell";
import type { Style, StyleTable } from "../../../protocol/schema/style";

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

  // Setup keyboard and IME handlers
  useEffect(() => {
    if (!terminalRef.current || isReadOnly) return;

    const keyboard = createKeyboardHandler();
    const ime = createIMEHandler();
    keyboardRef.current = keyboard;
    imeRef.current = ime;

    // Attach IME first - creates hidden textarea for composition input
    ime.attach(terminalRef.current);
    ime.setPaneId(paneId);

    // Get the textarea element created by IME for keyboard attachment
    // KeyboardHandler must attach to the same element for focus to work
    const inputElement = ime.getElement();
    if (!inputElement) {
      console.error("IME failed to create input element");
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
      getSelection: () => getSelection(),
      readClipboard: () => pasteFromClipboard(),
      writeClipboard: async (text: string) => {
        await copyToClipboard(text);
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
      openSettings: () => setSettingsOpen(true),
      setFocusedPane: (targetPaneId: number) => setFocusedPane(targetPaneId),
      getPaneIds: () => {
        const store = getStore();
        const activeWindow = store.windows.get(store.activeWindowId);
        return activeWindow?.paneIds ?? [];
      },
      getFocusedPaneId: () => getStore().focusedPaneId,
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

    ime.setCallback((msg) => {
      if (connection?.isConnected) {
        connection.sendText(msg);
      }
      onKeyInput?.();
    });

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

      // Convert wheel delta to rows (roughly 3 rows per scroll tick)
      const delta = Math.sign(e.deltaY) * 3;
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

  // Convert cells to styled runs
  const lines = cellsToRuns(cells, styles, cols, rows);

  // Show scrollback indicator if not at bottom
  const isScrolledUp =
    snapshot.scrollback.viewportTop < snapshot.scrollback.totalRows - rows;

  return (
    <pre
      class="terminal"
      ref={terminalRef}
      tabIndex={0}
    >
      {isScrolledUp && (
        <div class="scrollback-indicator">
          {snapshot.scrollback.totalRows - snapshot.scrollback.viewportTop - rows} lines above
        </div>
      )}
      {lines.map((runs, y) => (
        <div key={y} class="terminal-line">
          {renderLine(
            runs,
            y,
            cursor,
            cursorStyle,
            cursorColor,
            cursorText,
            cursorBlink,
            isActive
          )}
        </div>
      ))}
    </pre>
  );
}

/** A run of consecutive cells with the same style */
interface Run {
  text: string;
  styleId: number;
  style: Style;
}

/** Convert cells to lines of styled runs */
function cellsToRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  rows: number
): Run[][] {
  const lines: Run[][] = [];

  for (let y = 0; y < rows; y++) {
    const runs: Run[] = [];
    let currentRun: Run | null = null;

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

/** Get cell color as CSS value */
function getCellColor(style: Style, type: "fg" | "bg"): string | undefined {
  const color = type === "fg" ? style.fgColor : style.bgColor;
  if (color.tag === ColorTag.RGB) {
    return `rgb(${color.r},${color.g},${color.b})`;
  } else if (color.tag === ColorTag.PALETTE) {
    return `var(--c${color.index})`;
  }
  return undefined;
}

/** Resolve cursor color setting to actual CSS value */
function resolveCursorColor(
  setting: string,
  cellStyle: Style,
  _defaultVar: string
): string | undefined {
  if (!setting) return undefined; // Use CSS default (theme color)
  if (setting === "cell-foreground") return getCellColor(cellStyle, "fg");
  if (setting === "cell-background") return getCellColor(cellStyle, "bg");
  return setting; // Custom color value
}

/** Render a line of runs, inserting cursor if needed */
function renderLine(
  runs: Run[],
  y: number,
  cursor: TerminalSnapshot["cursor"],
  cursorStyle: "block" | "bar" | "underline" | "block_hollow",
  cursorColor: string,
  cursorText: string,
  cursorBlink: "" | "true" | "false",
  isActive: boolean
): preact.JSX.Element {
  // Only show cursor on active pane, and only if cursor is visible and on this line
  if (!isActive || !cursor.visible || cursor.y !== y) {
    return (
      <>
        {runs.map((run, i) => (
          <span
            key={i}
            class={styleToClasses(run.style)}
            style={styleToInline(run.style)}
          >
            {run.text}
          </span>
        ))}
      </>
    );
  }

  // Cursor is on this line - need to split at cursor position
  const elements: preact.JSX.Element[] = [];
  let x = 0;
  // Determine if cursor should blink:
  // - '' (auto): use server's DEC Mode 12 state (cursor.blink)
  // - 'true': always blink (override server)
  // - 'false': never blink (override server)
  const shouldBlink =
    cursorBlink === "" ? cursor.blink : cursorBlink === "true";
  const cursorClass = `cursor-${cursorStyle}${shouldBlink ? " cursor-blink" : ""}`;
  // For non-block cursors, preserve original text styling
  const preserveStyle = cursorStyle !== "block";

  for (let i = 0; i < runs.length; i++) {
    const run = runs[i]!;
    const runStart = x;
    const runEnd = x + run.text.length;

    if (cursor.x >= runStart && cursor.x < runEnd) {
      // Cursor is in this run - split it
      const offset = cursor.x - runStart;
      const before = run.text.slice(0, offset);
      const cursorChar = run.text[offset] || " ";
      const after = run.text.slice(offset + 1);

      if (before) {
        elements.push(
          <span
            key={`${i}-before`}
            class={styleToClasses(run.style)}
            style={styleToInline(run.style)}
          >
            {before}
          </span>
        );
      }

      // Build cursor style
      const baseStyle = preserveStyle ? styleToInline(run.style) || {} : {};
      const cursorBg = resolveCursorColor(
        cursorColor,
        run.style,
        "--term-cursor-bg"
      );
      const cursorFg = resolveCursorColor(
        cursorText,
        run.style,
        "--term-cursor-fg"
      );

      const cursorInlineStyle: h.JSX.CSSProperties = { ...baseStyle };
      if (cursorBg) {
        cursorInlineStyle["--cursor-bg"] = cursorBg;
      }
      if (cursorFg && cursorStyle === "block") {
        // Text color only applies to block cursor
        cursorInlineStyle.color = cursorFg;
      }

      const classes = preserveStyle
        ? `${cursorClass} ${styleToClasses(run.style)}`.trim()
        : cursorClass;

      elements.push(
        <span
          key={`${i}-cursor`}
          class={classes}
          style={
            Object.keys(cursorInlineStyle).length
              ? cursorInlineStyle
              : undefined
          }
        >
          {cursorChar}
        </span>
      );

      if (after) {
        elements.push(
          <span
            key={`${i}-after`}
            class={styleToClasses(run.style)}
            style={styleToInline(run.style)}
          >
            {after}
          </span>
        );
      }
    } else {
      elements.push(
        <span
          key={i}
          class={styleToClasses(run.style)}
          style={styleToInline(run.style)}
        >
          {run.text}
        </span>
      );
    }

    x = runEnd;
  }

  // Cursor beyond end of line
  if (cursor.x >= x) {
    elements.push(
      <span key="cursor-end" class={cursorClass}>
        {" "}
      </span>
    );
  }

  return <>{elements}</>;
}

/** Convert style to CSS class names (for palette colors + attributes) */
function styleToClasses(style: Style): string {
  const classes: string[] = [];

  // Handle inverse by swapping fg/bg
  const fgColor = style.flags.inverse ? style.bgColor : style.fgColor;
  const bgColor = style.flags.inverse ? style.fgColor : style.bgColor;

  // Foreground color (palette only - RGB uses inline style)
  if (fgColor.tag === ColorTag.PALETTE) {
    classes.push(`fg${fgColor.index}`);
  }

  // Background color (palette only)
  if (bgColor.tag === ColorTag.PALETTE) {
    classes.push(`bg${bgColor.index}`);
  }

  // Attributes (inverse handled above, not as a class)
  if (style.flags.bold) classes.push("bold");
  if (style.flags.italic) classes.push("italic");
  if (style.flags.faint) classes.push("faint");
  if (style.flags.blink) classes.push("blink");
  if (style.flags.invisible) classes.push("invisible");
  if (style.flags.strikethrough) classes.push("strikethrough");
  if (style.flags.overline) classes.push("overline");

  // Underline styles
  switch (style.flags.underline) {
    case Underline.SINGLE:
      classes.push("underline");
      break;
    case Underline.DOUBLE:
      classes.push("underline-double");
      break;
    case Underline.CURLY:
      classes.push("underline-curly");
      break;
    case Underline.DOTTED:
      classes.push("underline-dotted");
      break;
    case Underline.DASHED:
      classes.push("underline-dashed");
      break;
  }

  return classes.join(" ");
}

/** Convert style to inline CSS (for RGB colors and inverse with defaults) */
function styleToInline(style: Style): h.JSX.CSSProperties | undefined {
  const css: h.JSX.CSSProperties = {};
  let hasInline = false;

  // Handle inverse by swapping fg/bg
  const fgColor = style.flags.inverse ? style.bgColor : style.fgColor;
  const bgColor = style.flags.inverse ? style.fgColor : style.bgColor;

  // When inverse is set and original color was NONE, use terminal defaults
  if (style.flags.inverse) {
    // If swapped fg (original bg) is NONE, use terminal bg as text color
    if (fgColor.tag === ColorTag.NONE) {
      css.color = "var(--term-bg)";
      hasInline = true;
    }
    // If swapped bg (original fg) is NONE, use terminal fg as background
    if (bgColor.tag === ColorTag.NONE) {
      css.backgroundColor = "var(--term-fg)";
      hasInline = true;
    }
  }

  // RGB foreground (only if not already set above)
  if (fgColor.tag === ColorTag.RGB) {
    css.color = `rgb(${fgColor.r},${fgColor.g},${fgColor.b})`;
    hasInline = true;
  }

  // RGB background (only if not already set above)
  if (bgColor.tag === ColorTag.RGB) {
    css.backgroundColor = `rgb(${bgColor.r},${bgColor.g},${bgColor.b})`;
    hasInline = true;
  }

  // Underline color (always inline if set, CSS doesn't support this well)
  if (style.underlineColor.tag === ColorTag.RGB) {
    css.textDecorationColor = `rgb(${style.underlineColor.r},${style.underlineColor.g},${style.underlineColor.b})`;
    hasInline = true;
  } else if (style.underlineColor.tag === ColorTag.PALETTE) {
    css.textDecorationColor = `var(--c${style.underlineColor.index})`;
    hasInline = true;
  }

  return hasInline ? css : undefined;
}
