// Cursor rendering utilities
// Handles cursor insertion and styling within terminal lines

import { h } from "preact";
import {
  styleToClasses,
  styleToInline,
  getCellColor,
  colorToCss,
} from "./terminalStyle";
import { handleHyperlinkClick } from "./hyperlink";
import type { StyledRun } from "./cellRendering";
import type { Style } from "../../../protocol/schema/style";
import { ColorTag } from "../../../protocol/schema/style";

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

/** Build class string for a run, including selection state and bgOverride palette */
function runClasses(run: StyledRun): string {
  let classes = styleToClasses(run.style);
  // Add palette bg class for bgOverride (content-based bg color)
  if (run.bgOverride?.tag === ColorTag.PALETTE) {
    classes = `${classes} bg${run.bgOverride.index}`.trim();
  }
  return run.selected ? `${classes} selected`.trim() : classes;
}

/** Get inline style for a run, including bgOverride RGB colors */
function runInlineStyle(run: StyledRun): h.JSX.CSSProperties | undefined {
  const baseStyle = styleToInline(run.style);
  // Add RGB background for bgOverride (content-based bg color)
  if (run.bgOverride?.tag === ColorTag.RGB) {
    const bgCss = colorToCss(run.bgOverride);
    if (bgCss) {
      return { ...baseStyle, backgroundColor: bgCss };
    }
  }
  return baseStyle;
}

/**
 * Render text content, wrapping wide characters in explicit-width spans.
 * Wide characters (CJK, emoji) need explicit 2-cell width for proper alignment
 * when mixed with different fallback fonts.
 */
function renderTextWithWideChars(
  text: string,
  wideIndices: number[] | undefined,
  baseClass: string,
  style: h.JSX.CSSProperties | undefined
): preact.JSX.Element | preact.JSX.Element[] {
  // No wide characters - render as single element
  if (!wideIndices || wideIndices.length === 0) {
    return (
      <span class={baseClass} style={style}>
        {text}
      </span>
    );
  }

  // Has wide characters - split and render segments
  const elements: preact.JSX.Element[] = [];
  const wideSet = new Set(wideIndices);
  let segmentStart = 0;

  for (let i = 0; i <= text.length; i++) {
    const isWide = wideSet.has(i);
    const isEnd = i === text.length;

    // When we hit a wide char or end, flush the narrow segment
    if ((isWide || isEnd) && i > segmentStart) {
      const narrowText = text.slice(segmentStart, i);
      elements.push(
        <span key={`n${segmentStart}`} class={baseClass} style={style}>
          {narrowText}
        </span>
      );
    }

    // Render wide character with explicit width
    if (isWide && i < text.length) {
      const wideChar = text[i];
      elements.push(
        <span key={`w${i}`} class={`${baseClass} wide-char`.trim()} style={style}>
          {wideChar}
        </span>
      );
      segmentStart = i + 1;
    } else if (isWide) {
      segmentStart = i + 1;
    }
  }

  return elements;
}

/**
 * Render a run element, either as a hyperlink (<a>) or a plain span.
 * Hyperlinks get special styling and click handling.
 * Wide characters are wrapped in explicit-width spans.
 */
function renderRunElement(
  run: StyledRun,
  key: string | number,
  text: string,
  extraClass?: string,
  extraStyle?: h.JSX.CSSProperties
): preact.JSX.Element {
  const classes = extraClass
    ? `${runClasses(run)} ${extraClass}`.trim()
    : runClasses(run);
  const style = extraStyle || runInlineStyle(run);

  // For hyperlinks, we render differently (as <a> tag)
  if (run.hyperlink) {
    // For hyperlinks with wide chars, we need to handle it specially
    if (run.wideIndices && run.wideIndices.length > 0) {
      return (
        <a
          key={key}
          class={`${classes} hyperlink`.trim()}
          style={style}
          href={run.hyperlink}
          title={run.hyperlink}
          onClick={(e: MouseEvent) => handleHyperlinkClick(e, run.hyperlink!)}
        >
          {renderTextWithWideChars(text, run.wideIndices, "", undefined)}
        </a>
      );
    }
    return (
      <a
        key={key}
        class={`${classes} hyperlink`.trim()}
        style={style}
        href={run.hyperlink}
        title={run.hyperlink}
        onClick={(e: MouseEvent) => handleHyperlinkClick(e, run.hyperlink!)}
      >
        {text}
      </a>
    );
  }

  // No wide characters - simple span
  if (!run.wideIndices || run.wideIndices.length === 0) {
    return (
      <span key={key} class={classes} style={style}>
        {text}
      </span>
    );
  }

  // Has wide characters - render with explicit widths
  return (
    <span key={key}>
      {renderTextWithWideChars(text, run.wideIndices, classes, style)}
    </span>
  );
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
        {runs.map((run, i) => renderRunElement(run, i, run.text))}
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
        elements.push(renderRunElement(run, `${i}-before`, before));
      }

      // Build cursor style
      const baseStyle = preserveStyle ? runInlineStyle(run) || {} : {};
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
        elements.push(renderRunElement(run, `${i}-after`, after));
      }
    } else {
      elements.push(renderRunElement(run, i, run.text));
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
