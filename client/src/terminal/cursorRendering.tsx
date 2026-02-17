// Cursor rendering utilities
// Handles cursor insertion and styling within terminal lines

import { h } from "preact";
import {
  styleToClassesCached,
  styleToInlineCached,
  getCellColor,
  colorToCss,
} from "./terminalStyle";
import type { StyledRun, WideCharRange } from "./cellRendering";
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

/** Build class string for a run, including selection state and bgOverride palette */
function runClasses(run: StyledRun): string {
  let classes = styleToClassesCached(run.styleId, run.style);
  // Add palette bg class for bgOverride (content-based bg color)
  if (run.bgOverride?.tag === ColorTag.PALETTE) {
    classes = `${classes} bg${run.bgOverride.index}`.trim();
  }
  return run.selected ? `${classes} selected`.trim() : classes;
}

function sortRanges(ranges?: WideCharRange[]): WideCharRange[] {
  if (!ranges || ranges.length === 0) {
    return [];
  }
  return [...ranges].sort((a, b) => a.start - b.start);
}

interface LineSegment {
  text: string;
  cells: number;
  isWide: boolean;
  isSingle: boolean;
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

function buildRunSegments(run: StyledRun): LineSegment[] {
  const baseClasses = runClasses(run);
  const baseStyle = runInlineStyle(run);
  const wideRanges = sortRanges(run.wideRanges);
  const singleRanges = sortRanges(run.singleRanges);
  let wideIndex = 0;
  let singleIndex = 0;
  let nextWide = wideRanges[0];
  let nextSingle = singleRanges[0];
  const segments: LineSegment[] = [];
  let bufferStart = 0;
  let bufferCells = 0;

  const flushBuffer = (end: number) => {
    if (bufferCells === 0) {
      return;
    }
    segments.push({
      text: run.text.slice(bufferStart, end),
      cells: bufferCells,
      isWide: false,
      isSingle: false,
      classes: baseClasses,
      style: baseStyle,
      hyperlink: run.hyperlink,
      styleRef: run.style,
    });
    bufferCells = 0;
  };

  for (let i = 0; i < run.text.length; ) {
    if (nextWide && nextWide.start === i) {
      flushBuffer(i);
      const end = nextWide.end;
      segments.push({
        text: run.text.slice(i, end),
        cells: 2,
        isWide: true,
        isSingle: false,
        classes: baseClasses,
        style: baseStyle,
        hyperlink: run.hyperlink,
        styleRef: run.style,
      });
      i = end;
      wideIndex += 1;
      nextWide = wideRanges[wideIndex];
      bufferStart = i;
      continue;
    }

    if (nextSingle && nextSingle.start === i) {
      flushBuffer(i);
      const end = nextSingle.end;
      segments.push({
        text: run.text.slice(i, end),
        cells: 1,
        isWide: false,
        isSingle: true,
        classes: baseClasses,
        style: baseStyle,
        hyperlink: run.hyperlink,
        styleRef: run.style,
      });
      i = end;
      singleIndex += 1;
      nextSingle = singleRanges[singleIndex];
      bufferStart = i;
      continue;
    }

    if (bufferCells === 0) {
      bufferStart = i;
    }
    const cp = run.text.codePointAt(i);
    const len = cp !== undefined && cp > 0xffff ? 2 : 1;
    bufferCells += 1;
    i += len;
  }

  flushBuffer(run.text.length);
  return segments;
}

function buildLineSegments(runs: StyledRun[], cols: number): PositionedSegment[] {
  const segments: PositionedSegment[] = [];
  let cellPos = 0;

  for (const run of runs) {
    const runSegments = buildRunSegments(run);
    for (const segment of runSegments) {
      if (cellPos >= cols) {
        break;
      }
      const remaining = cols - cellPos;
      if (segment.cells <= remaining) {
        const startCell = cellPos;
        const endCell = cellPos + segment.cells;
        segments.push({ ...segment, startCell, endCell });
        cellPos = endCell;
      } else {
        if (segment.isWide || remaining === 0) {
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
    if (cellPos >= cols) {
      break;
    }
  }

  while (cellPos < cols) {
    const remaining = cols - cellPos;
    segments.push({
      text: " ".repeat(remaining),
      cells: remaining,
      isWide: false,
      isSingle: false,
      classes: "",
      style: undefined,
      styleRef: DEFAULT_STYLE,
      startCell: cellPos,
      endCell: cellPos + remaining,
    });
    cellPos = cols;
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
 * Render text content, wrapping wide characters in explicit-width spans.
 * Wide characters (CJK, emoji) need explicit 2-cell width for proper alignment
 * when mixed with different fallback fonts. Private-use glyphs can be
 * constrained to a single cell.
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
      const baseStyle = preserveStyle ? segment.style || {} : {};
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

      const cursorInlineStyle: h.JSX.CSSProperties = { ...baseStyle };
      if (cursorBg) {
        cursorInlineStyle["--cursor-bg"] = cursorBg;
      }
      if (cursorFg && cursorConfig.style === "block") {
        cursorInlineStyle.color = cursorFg;
      }

      const widthClass = segment.isWide
        ? "wide-char"
        : segment.isSingle
          ? "single-char"
          : "";
      const classesBase = preserveStyle
        ? `${cursorClass} ${segment.classes}`.trim()
        : cursorClass;
      const classes = [classesBase, widthClass].filter(Boolean).join(" ");

      if (segment.isWide) {
        elements.push(
          <span
            key={`s-${i}-cursor`}
            class={classes}
            style={
              Object.keys(cursorInlineStyle).length
                ? cursorInlineStyle
                : undefined
            }
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
                isWide: false,
                isSingle: false,
              },
              `s-${i}-before`
            )
          );
        }

        elements.push(
          <span
            key={`s-${i}-cursor`}
            class={classes}
            style={
              Object.keys(cursorInlineStyle).length
                ? cursorInlineStyle
                : undefined
            }
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
                isWide: false,
                isSingle: false,
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
  const widthClass = segment.isWide
    ? "wide-char"
    : segment.isSingle
      ? "single-char"
      : "";
  const baseClasses = [segment.classes, widthClass].filter(Boolean).join(" ");
  const classes = segment.hyperlink
    ? `${baseClasses} hyperlink`.trim()
    : baseClasses;

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
