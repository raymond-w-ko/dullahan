// Cursor rendering utilities
// Handles cursor insertion and styling within terminal lines

import { h } from "preact";
import {
  styleToClassesCached,
  styleToInlineCached,
  getCellColor,
  colorToCss,
} from "./terminalStyle";
import type { StyledRun } from "./cellRendering";
import type { Style } from "../../../protocol/schema/style";
import { ColorTag, DEFAULT_STYLE } from "../../../protocol/schema/style";

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

function appendClass(base: string, extra: string): string {
  return base ? `${base} ${extra}` : extra;
}

function appendFixedWidthClass(classes: string, fixedWidth?: 1 | 2): string {
  if (fixedWidth === undefined) return classes;
  return appendClass(
    classes,
    fixedWidth === 2 ? "fixed-cell fixed-cell-wide" : "fixed-cell"
  );
}

/** Build class string for a run, including selection state and bgOverride palette */
function runClasses(run: StyledRun): string {
  let classes = styleToClassesCached(run.styleId, run.style);
  // Add palette bg class for bgOverride (content-based bg color)
  if (run.bgOverride?.tag === ColorTag.PALETTE) {
    classes = appendClass(classes, `bg${run.bgOverride.index}`);
  }
  return run.selected ? appendClass(classes, "selected") : classes;
}

interface LineSegment {
  text: string;
  cells: number;
  fixedWidth?: 1 | 2;
  classes: string;
  style: h.JSX.CSSProperties | undefined;
  hyperlink?: string;
  styleRef: Style;
}

interface PositionedSegment extends LineSegment {
  startCell: number;
  endCell: number;
}

// Cache line segmentation by runs identity and column count so cursor-only
// updates can reuse prior segment computation.
const lineSegmentsCache = new WeakMap<StyledRun[], Map<number, PositionedSegment[]>>();

function countCodepoints(text: string): number {
  let count = 0;
  for (const _ of text) {
    count += 1;
  }
  return count;
}

function sliceCodepoints(text: string, count: number): string {
  if (count <= 0) return "";
  let idx = 0;
  let pos = 0;
  for (const ch of text) {
    if (idx === count) {
      break;
    }
    pos += ch.length;
    idx += 1;
  }
  return text.slice(0, pos);
}

function splitAtCodepoint(text: string, index: number): { before: string; rest: string } {
  if (index <= 0) {
    return { before: "", rest: text };
  }
  let idx = 0;
  let pos = 0;
  for (const ch of text) {
    if (idx === index) {
      break;
    }
    pos += ch.length;
    idx += 1;
  }
  return { before: text.slice(0, pos), rest: text.slice(pos) };
}

function takeFirstCodepoint(text: string): { ch: string; rest: string } {
  for (const ch of text) {
    return { ch, rest: text.slice(ch.length) };
  }
  return { ch: "", rest: "" };
}

function buildLineSegments(runs: StyledRun[], cols: number): PositionedSegment[] {
  const segments: PositionedSegment[] = [];
  let cellPos = 0;

  for (const run of runs) {
    if (cellPos >= cols) break;
    const segment: LineSegment = {
      text: run.text,
      cells: run.cellCount,
      fixedWidth: run.fixedWidth,
      classes: runClasses(run),
      style: runInlineStyle(run),
      hyperlink: run.hyperlink,
      styleRef: run.style,
    };
    const remaining = cols - cellPos;
    if (segment.cells <= remaining) {
      const startCell = cellPos;
      const endCell = cellPos + segment.cells;
      segments.push({ ...segment, startCell, endCell });
      cellPos = endCell;
    } else {
      if (segment.fixedWidth !== undefined || remaining === 0) {
        cellPos = cols;
        break;
      }
      const truncatedText = sliceCodepoints(segment.text, remaining);
      if (truncatedText.length > 0) {
        const startCell = cellPos;
        const endCell = cellPos + remaining;
        segments.push({
          ...segment,
          text: truncatedText,
          cells: remaining,
          startCell,
          endCell,
        });
      }
      cellPos = cols;
      break;
    }
  }

  if (cellPos < cols) {
    const remaining = cols - cellPos;
    segments.push({
      text: " ".repeat(remaining),
      cells: remaining,
      classes: "",
      style: undefined,
      styleRef: DEFAULT_STYLE,
      startCell: cellPos,
      endCell: cellPos + remaining,
    });
  }

  return segments;
}

function getLineSegments(runs: StyledRun[], cols: number): PositionedSegment[] {
  let byCols = lineSegmentsCache.get(runs);
  if (!byCols) {
    byCols = new Map<number, PositionedSegment[]>();
    lineSegmentsCache.set(runs, byCols);
  }

  const cached = byCols.get(cols);
  if (cached) {
    return cached;
  }

  const built = buildLineSegments(runs, cols);
  byCols.set(cols, built);
  return built;
}

/** Get inline style for a run, including bgOverride RGB colors */
function runInlineStyle(run: StyledRun): h.JSX.CSSProperties | undefined {
  const baseStyle = styleToInlineCached(run.styleId, run.style);
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
 * Render text content with explicit-width spans already isolated by the cell
 * conversion pass.
 */
/** Render a line of runs, inserting cursor if needed */
export function renderLine(
  runs: StyledRun[],
  y: number,
  cursor: CursorState,
  cursorConfig: CursorConfig,
  isActive: boolean,
  cols: number
): preact.JSX.Element {
  const segments = getLineSegments(runs, cols);
  // Determine if cursor should blink:
  // - '' (auto): use server's DEC Mode 12 state (cursor.blink)
  // - 'true': always blink (override server)
  // - 'false': never blink (override server)
  const shouldBlink =
    cursorConfig.blink === "" ? cursor.blink : cursorConfig.blink === "true";
  const cursorClass = `cursor-${cursorConfig.style}${shouldBlink ? " cursor-blink" : ""}`;
  // For non-block cursors, preserve original text styling
  const preserveStyle = cursorConfig.style !== "block";
  const showCursor = isActive && cursor.visible && cursor.y === y;
  const elements: preact.JSX.Element[] = [];
  let cursorRendered = false;

  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i]!;
    const isCursor = showCursor &&
      cursor.x >= segment.startCell &&
      cursor.x < segment.endCell;
    if (isCursor) {
      cursorRendered = true;
      const cursorBg = resolveCursorColor(
        cursorConfig.color,
        segment.styleRef,
        "--term-cursor-bg"
      );
      const cursorFg = resolveCursorColor(
        cursorConfig.textColor,
        segment.styleRef,
        "--term-cursor-fg"
      );

      let cursorInlineStyle: h.JSX.CSSProperties | undefined = preserveStyle
        ? segment.style
        : undefined;
      if (cursorBg || (cursorFg && cursorConfig.style === "block")) {
        cursorInlineStyle = cursorInlineStyle ? { ...cursorInlineStyle } : {};
        if (cursorBg) {
          cursorInlineStyle["--cursor-bg"] = cursorBg;
        }
        if (cursorFg && cursorConfig.style === "block") {
          cursorInlineStyle.color = cursorFg;
        }
      }

      const classesBase = preserveStyle
        ? appendClass(cursorClass, segment.classes)
        : cursorClass;
      const classes = appendFixedWidthClass(classesBase, segment.fixedWidth);

      if (segment.fixedWidth !== undefined) {
        elements.push(
          <span
            key={`s-${i}-cursor`}
            class={classes}
            style={cursorInlineStyle}
          >
            {segment.text}
          </span>
        );
      } else {
        const offset = cursor.x - segment.startCell;
        const { before, rest } = splitAtCodepoint(segment.text, offset);
        const { ch: cursorChar, rest: after } = takeFirstCodepoint(rest);

        if (before.length > 0) {
          elements.push(
            renderSegmentElement(
              {
                ...segment,
                text: before,
                cells: countCodepoints(before),
                fixedWidth: undefined,
              },
              `s-${i}-before`
            )
          );
        }

        elements.push(
          <span
            key={`s-${i}-cursor`}
            class={classes}
            style={cursorInlineStyle}
          >
            {cursorChar || " "}
          </span>
        );

        if (after.length > 0) {
          elements.push(
            renderSegmentElement(
              {
                ...segment,
                text: after,
                cells: countCodepoints(after),
                fixedWidth: undefined,
              },
              `s-${i}-after`
            )
          );
        }
      }
      continue;
    }

    elements.push(renderSegmentElement(segment, `s-${i}`));
  }

  if (showCursor && !cursorRendered && cursor.x >= cols) {
    elements.push(
      <span key="cursor-end" class={cursorClass}>
        {" "}
      </span>
    );
  }

  return <>{elements}</>;
}

function renderSegmentElement(
  segment: LineSegment,
  key: string
): preact.JSX.Element {
  let classes = appendFixedWidthClass(segment.classes, segment.fixedWidth);
  if (segment.hyperlink) {
    classes = appendClass(classes, "hyperlink");
  }

  if (segment.hyperlink) {
    return (
      <a
        key={key}
        class={classes}
        style={segment.style}
        href={segment.hyperlink}
        title={segment.hyperlink}
      >
        {segment.text}
      </a>
    );
  }

  return (
    <span key={key} class={classes} style={segment.style}>
      {segment.text}
    </span>
  );
}
