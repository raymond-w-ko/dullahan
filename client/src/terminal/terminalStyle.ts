// Terminal style conversion utilities
// Converts ghostty Style objects to CSS classes and inline styles

import { h } from "preact";
import { ColorTag, Underline } from "../../../protocol/schema/style";
import type { Style, Color } from "../../../protocol/schema/style";

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
