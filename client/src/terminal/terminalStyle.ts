// Terminal style conversion utilities
// Converts ghostty Style objects to CSS classes and inline styles

import { h } from "preact";
import { ColorTag, Underline } from "../../../protocol/schema/style";
import type { Style, Color } from "../../../protocol/schema/style";

interface RgbColor {
  r: number;
  g: number;
  b: number;
}

interface ThemeColors {
  themeName: string;
  appEl: Element;
  termFg?: RgbColor;
  termBg?: RgbColor;
  palette: Array<RgbColor | undefined>;
}

const FAINT_OPACITY = 0.5;

let cachedTheme: ThemeColors | null = null;

function parseCssColor(value: string): RgbColor | undefined {
  const trimmed = value.trim().toLowerCase();
  if (!trimmed) return undefined;

  if (trimmed.startsWith("#")) {
    const hex = trimmed.slice(1);
    if (hex.length === 3) {
      const r = parseInt(hex.slice(0, 1) + hex.slice(0, 1), 16);
      const g = parseInt(hex.slice(1, 2) + hex.slice(1, 2), 16);
      const b = parseInt(hex.slice(2, 3) + hex.slice(2, 3), 16);
      return { r, g, b };
    }
    if (hex.length === 6) {
      const r = parseInt(hex.slice(0, 2), 16);
      const g = parseInt(hex.slice(2, 4), 16);
      const b = parseInt(hex.slice(4, 6), 16);
      return { r, g, b };
    }
    return undefined;
  }

  const rgbMatch = trimmed.match(/rgba?\(([^)]+)\)/);
  if (!rgbMatch) return undefined;
  const rgbBody = rgbMatch[1];
  if (!rgbBody) return undefined;
  const parts = rgbBody
    .split(/[,/ ]+/)
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
  if (parts.length < 3) return undefined;

  const parseChannel = (part: string): number | null => {
    if (part.endsWith("%")) {
      const pct = Number.parseFloat(part);
      if (Number.isNaN(pct)) return null;
      return Math.round((pct / 100) * 255);
    }
    const num = Number.parseFloat(part);
    if (Number.isNaN(num)) return null;
    return Math.round(num);
  };

  const p0 = parts[0];
  const p1 = parts[1];
  const p2 = parts[2];
  if (!p0 || !p1 || !p2) return undefined;
  const r = parseChannel(p0);
  const g = parseChannel(p1);
  const b = parseChannel(p2);
  if (r === null || g === null || b === null) return undefined;
  return {
    r: Math.min(255, Math.max(0, r)),
    g: Math.min(255, Math.max(0, g)),
    b: Math.min(255, Math.max(0, b)),
  };
}

function getThemeColors(): ThemeColors | null {
  if (typeof document === "undefined") return cachedTheme;
  const appEl = document.querySelector(".app");
  if (!appEl) return cachedTheme;
  const themeName = appEl.getAttribute("data-theme") ?? "";
  if (cachedTheme && cachedTheme.appEl === appEl && cachedTheme.themeName === themeName) {
    return cachedTheme;
  }

  const style = getComputedStyle(appEl);
  const palette: Array<RgbColor | undefined> = [];
  for (let i = 0; i < 16; i++) {
    palette.push(parseCssColor(style.getPropertyValue(`--c${i}`)));
  }

  cachedTheme = {
    themeName,
    appEl,
    termFg: parseCssColor(style.getPropertyValue("--term-fg")),
    termBg: parseCssColor(style.getPropertyValue("--term-bg")),
    palette,
  };
  return cachedTheme;
}

function resolveRgb(
  color: Color,
  theme: ThemeColors | null,
  fallback?: RgbColor
): RgbColor | undefined {
  switch (color.tag) {
    case ColorTag.RGB:
      return { r: color.r, g: color.g, b: color.b };
    case ColorTag.PALETTE:
      return theme?.palette[color.index] ?? fallback;
    case ColorTag.NONE:
    default:
      return fallback;
  }
}

function blendRgb(fg: RgbColor, bg: RgbColor, alpha: number): string {
  const inv = 1 - alpha;
  const r = Math.round(fg.r * alpha + bg.r * inv);
  const g = Math.round(fg.g * alpha + bg.g * inv);
  const b = Math.round(fg.b * alpha + bg.b * inv);
  return `rgb(${r},${g},${b})`;
}

/** Get cell color as CSS value */
export function getCellColor(style: Style, type: "fg" | "bg"): string | undefined {
  const color = type === "fg" ? style.fgColor : style.bgColor;
  if (color.tag === ColorTag.RGB) {
    return `rgb(${color.r},${color.g},${color.b})`;
  } else if (color.tag === ColorTag.PALETTE) {
    return `var(--c${color.index})`;
  }
  return undefined;
}

/** Convert a Color to CSS value, or undefined if NONE */
export function colorToCss(color: Color): string | undefined {
  if (color.tag === ColorTag.RGB) {
    return `rgb(${color.r},${color.g},${color.b})`;
  } else if (color.tag === ColorTag.PALETTE) {
    return `var(--c${color.index})`;
  }
  return undefined;
}

/** Convert style to CSS class names (for palette colors + attributes) */
export function styleToClasses(style: Style): string {
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
export function styleToInline(style: Style): h.JSX.CSSProperties | undefined {
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

  // Faint: dim foreground only by blending with effective background
  if (style.flags.faint) {
    const theme = getThemeColors();
    const termFg = theme?.termFg;
    const termBg = theme?.termBg;
    const fgRgb = resolveRgb(fgColor, theme, termFg);
    const bgRgb = resolveRgb(bgColor, theme, termBg);

    if (fgRgb && bgRgb) {
      css.color = blendRgb(fgRgb, bgRgb, FAINT_OPACITY);
      hasInline = true;
    } else if (fgRgb) {
      css.color = `rgb(${fgRgb.r},${fgRgb.g},${fgRgb.b})`;
      hasInline = true;
    } else {
      // Fallback to whole-cell opacity if we cannot resolve theme colors
      css.opacity = FAINT_OPACITY;
      hasInline = true;
    }
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
