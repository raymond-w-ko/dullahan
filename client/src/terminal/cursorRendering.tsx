// Cursor rendering utilities
// Handles cursor insertion and styling within terminal lines

import { h } from "preact";
import { styleToClasses, styleToInline, getCellColor } from "./terminalStyle";
import type { StyledRun } from "./cellRendering";
import type { Style } from "../../../protocol/schema/style";

/** Cursor configuration from user settings */
export interface CursorConfig {
  style: "block" | "bar" | "underline" | "block_hollow";
  color: string;
  textColor: string;
  blink: "" | "true" | "false";
}

/** Cursor state from terminal snapshot */
export interface CursorState {
  x: number;
  y: number;
  visible: boolean;
  blink: boolean;
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

/** Build class string for a run, including selection state */
function runClasses(run: StyledRun): string {
  const classes = styleToClasses(run.style);
  return run.selected ? `${classes} selected`.trim() : classes;
}

/** Render a line of runs, inserting cursor if needed */
export function renderLine(
  runs: StyledRun[],
  y: number,
  cursor: CursorState,
  cursorConfig: CursorConfig,
  isActive: boolean
): preact.JSX.Element {
  // Only show cursor on active pane, and only if cursor is visible and on this line
  if (!isActive || !cursor.visible || cursor.y !== y) {
    return (
      <>
        {runs.map((run, i) => (
          <span
            key={i}
            class={runClasses(run)}
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
    cursorConfig.blink === "" ? cursor.blink : cursorConfig.blink === "true";
  const cursorClass = `cursor-${cursorConfig.style}${shouldBlink ? " cursor-blink" : ""}`;
  // For non-block cursors, preserve original text styling
  const preserveStyle = cursorConfig.style !== "block";

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
            class={runClasses(run)}
            style={styleToInline(run.style)}
          >
            {before}
          </span>
        );
      }

      // Build cursor style
      const baseStyle = preserveStyle ? styleToInline(run.style) || {} : {};
      const cursorBg = resolveCursorColor(
        cursorConfig.color,
        run.style,
        "--term-cursor-bg"
      );
      const cursorFg = resolveCursorColor(
        cursorConfig.textColor,
        run.style,
        "--term-cursor-fg"
      );

      const cursorInlineStyle: h.JSX.CSSProperties = { ...baseStyle };
      if (cursorBg) {
        cursorInlineStyle["--cursor-bg"] = cursorBg;
      }
      if (cursorFg && cursorConfig.style === "block") {
        // Text color only applies to block cursor
        cursorInlineStyle.color = cursorFg;
      }

      const classes = preserveStyle
        ? `${cursorClass} ${runClasses(run)}`.trim()
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
            class={runClasses(run)}
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
          class={runClasses(run)}
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
