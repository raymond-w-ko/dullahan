// Cursor rendering utilities
// Handles cursor insertion and styling within terminal lines

import { h } from "preact";
import {
  styleToClasses,
  styleToInline,
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
  let classes = styleToClasses(run.style);
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

interface GlyphSegment {
  text: string;
  cells: number;
  isWide: boolean;
  isSingle: boolean;
  classes: string;
  style: h.JSX.CSSProperties | undefined;
  hyperlink?: string;
  styleRef: Style;
}

interface PositionedGlyph extends GlyphSegment {
  startCell: number;
  endCell: number;
}

function buildRunGlyphs(run: StyledRun): GlyphSegment[] {
  const baseClasses = runClasses(run);
  const baseStyle = runInlineStyle(run);
  const wideRanges = sortRanges(run.wideRanges);
  const singleRanges = sortRanges(run.singleRanges);
  let wideIndex = 0;
  let singleIndex = 0;
  let nextWide = wideRanges[0];
  let nextSingle = singleRanges[0];
  const glyphs: GlyphSegment[] = [];

  for (let i = 0; i < run.text.length; ) {
    if (nextWide && nextWide.start === i) {
      const end = nextWide.end;
      glyphs.push({
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
      continue;
    }

    if (nextSingle && nextSingle.start === i) {
      const end = nextSingle.end;
      glyphs.push({
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
      continue;
    }

    const cp = run.text.codePointAt(i);
    const len = cp !== undefined && cp > 0xffff ? 2 : 1;
    glyphs.push({
      text: run.text.slice(i, i + len),
      cells: 1,
      isWide: false,
      isSingle: false,
      classes: baseClasses,
      style: baseStyle,
      hyperlink: run.hyperlink,
      styleRef: run.style,
    });
    i += len;
  }

  return glyphs;
}

function buildLineGlyphs(runs: StyledRun[], cols: number): PositionedGlyph[] {
  const glyphs: PositionedGlyph[] = [];
  let cellPos = 0;

  for (const run of runs) {
    const runGlyphs = buildRunGlyphs(run);
    for (const glyph of runGlyphs) {
      const startCell = cellPos;
      const endCell = cellPos + glyph.cells;
      glyphs.push({ ...glyph, startCell, endCell });
      cellPos = endCell;
    }
  }

  // Normalize to exact column count
  if (cellPos > cols) {
    while (glyphs.length > 0 && cellPos > cols) {
      const last = glyphs.pop();
      if (!last) {
        break;
      }
      cellPos -= last.cells;
    }
  }

  while (cellPos < cols) {
    glyphs.push({
      text: " ",
      cells: 1,
      isWide: false,
      isSingle: false,
      classes: "",
      style: undefined,
      styleRef: DEFAULT_STYLE,
      startCell: cellPos,
      endCell: cellPos + 1,
    });
    cellPos += 1;
  }

  return glyphs;
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
  const glyphs = buildLineGlyphs(runs, cols);
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

  for (let i = 0; i < glyphs.length; i++) {
    const glyph = glyphs[i]!;
    const isCursor = showCursor &&
      cursor.x >= glyph.startCell &&
      cursor.x < glyph.endCell;
    if (isCursor) {
      cursorRendered = true;
      const baseStyle = preserveStyle ? glyph.style || {} : {};
      const cursorBg = resolveCursorColor(
        cursorConfig.color,
        glyph.styleRef,
        "--term-cursor-bg"
      );
      const cursorFg = resolveCursorColor(
        cursorConfig.textColor,
        glyph.styleRef,
        "--term-cursor-fg"
      );

      const cursorInlineStyle: h.JSX.CSSProperties = { ...baseStyle };
      if (cursorBg) {
        cursorInlineStyle["--cursor-bg"] = cursorBg;
      }
      if (cursorFg && cursorConfig.style === "block") {
        cursorInlineStyle.color = cursorFg;
      }

      const widthClass = glyph.isWide
        ? "wide-char"
        : glyph.isSingle
          ? "single-char"
          : "";
      const classesBase = preserveStyle
        ? `${cursorClass} ${glyph.classes}`.trim()
        : cursorClass;
      const classes = [classesBase, widthClass].filter(Boolean).join(" ");
      elements.push(
        <span
          key={`g-${i}`}
          class={classes}
          style={
            Object.keys(cursorInlineStyle).length
              ? cursorInlineStyle
              : undefined
          }
        >
          {glyph.text}
        </span>
      );
      continue;
    }

    const widthClass = glyph.isWide
      ? "wide-char"
      : glyph.isSingle
        ? "single-char"
        : "";
    const baseClasses = [glyph.classes, widthClass].filter(Boolean).join(" ");
    const classes = glyph.hyperlink
      ? `${baseClasses} hyperlink`.trim()
      : baseClasses;

    if (glyph.hyperlink) {
      elements.push(
        <a
          key={`g-${i}`}
          class={classes}
          style={glyph.style}
          href={glyph.hyperlink}
          title={glyph.hyperlink}
        >
          {glyph.text}
        </a>
      );
    } else {
      elements.push(
        <span key={`g-${i}`} class={classes} style={glyph.style}>
          {glyph.text}
        </span>
      );
    }
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
