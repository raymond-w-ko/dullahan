/**
 * Style encoding/decoding for dullahan terminal protocol.
 *
 * Styles define colors and attributes (bold, italic, etc.) for terminal cells.
 * Cells reference styles by style_id (16-bit index).
 *
 * Binary format per style (14 bytes):
 *   bytes 0-3:   fg_color (1 byte tag + 3 bytes value)
 *   bytes 4-7:   bg_color (1 byte tag + 3 bytes value)
 *   bytes 8-11:  underline_color (1 byte tag + 3 bytes value)
 *   bytes 12-13: flags (16-bit packed)
 *
 * Color tag:
 *   0 = none (no color, use default)
 *   1 = palette (8-bit palette index in byte 1)
 *   2 = rgb (r, g, b in bytes 1, 2, 3)
 *
 * Flags (16 bits):
 *   bit 0: bold
 *   bit 1: italic
 *   bit 2: faint
 *   bit 3: blink
 *   bit 4: inverse
 *   bit 5: invisible
 *   bit 6: strikethrough
 *   bit 7: overline
 *   bits 8-10: underline (0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed)
 *   bits 11-15: padding
 */

/** Color type tag */
export const ColorTag = {
  NONE: 0,
  PALETTE: 1,
  RGB: 2,
} as const;

export type ColorTagValue = (typeof ColorTag)[keyof typeof ColorTag];

/** Color value */
export type Color =
  | { tag: typeof ColorTag.NONE }
  | { tag: typeof ColorTag.PALETTE; index: number }
  | { tag: typeof ColorTag.RGB; r: number; g: number; b: number };

/** Underline style */
export const Underline = {
  NONE: 0,
  SINGLE: 1,
  DOUBLE: 2,
  CURLY: 3,
  DOTTED: 4,
  DASHED: 5,
} as const;

export type UnderlineValue = (typeof Underline)[keyof typeof Underline];

/** Style flags */
export interface StyleFlags {
  bold: boolean;
  italic: boolean;
  faint: boolean;
  blink: boolean;
  inverse: boolean;
  invisible: boolean;
  strikethrough: boolean;
  overline: boolean;
  underline: UnderlineValue;
}

/** Complete style definition */
export interface Style {
  fgColor: Color;
  bgColor: Color;
  underlineColor: Color;
  flags: StyleFlags;
}

/** Default style (style_id 0) */
export const DEFAULT_STYLE: Style = {
  fgColor: { tag: ColorTag.NONE },
  bgColor: { tag: ColorTag.NONE },
  underlineColor: { tag: ColorTag.NONE },
  flags: {
    bold: false,
    italic: false,
    faint: false,
    blink: false,
    inverse: false,
    invisible: false,
    strikethrough: false,
    overline: false,
    underline: Underline.NONE,
  },
};

/** Size of one encoded style in bytes */
export const STYLE_BYTE_SIZE = 14;

/**
 * Encode a color to 4 bytes [tag, v0, v1, v2]
 */
export function encodeColor(color: Color): [number, number, number, number] {
  switch (color.tag) {
    case ColorTag.NONE:
      return [ColorTag.NONE, 0, 0, 0];
    case ColorTag.PALETTE:
      return [ColorTag.PALETTE, color.index & 0xff, 0, 0];
    case ColorTag.RGB:
      return [ColorTag.RGB, color.r & 0xff, color.g & 0xff, color.b & 0xff];
  }
}

/**
 * Decode a color from 4 bytes
 */
export function decodeColor(
  tag: number,
  v0: number,
  v1: number,
  v2: number
): Color {
  switch (tag) {
    case ColorTag.PALETTE:
      return { tag: ColorTag.PALETTE, index: v0 };
    case ColorTag.RGB:
      return { tag: ColorTag.RGB, r: v0, g: v1, b: v2 };
    default:
      return { tag: ColorTag.NONE };
  }
}

/**
 * Encode style flags to 16-bit value
 */
export function encodeFlags(flags: StyleFlags): number {
  return (
    (flags.bold ? 1 : 0) |
    ((flags.italic ? 1 : 0) << 1) |
    ((flags.faint ? 1 : 0) << 2) |
    ((flags.blink ? 1 : 0) << 3) |
    ((flags.inverse ? 1 : 0) << 4) |
    ((flags.invisible ? 1 : 0) << 5) |
    ((flags.strikethrough ? 1 : 0) << 6) |
    ((flags.overline ? 1 : 0) << 7) |
    ((flags.underline & 0x7) << 8)
  );
}

/**
 * Decode style flags from 16-bit value
 */
export function decodeFlags(value: number): StyleFlags {
  return {
    bold: (value & 0x1) !== 0,
    italic: (value & 0x2) !== 0,
    faint: (value & 0x4) !== 0,
    blink: (value & 0x8) !== 0,
    inverse: (value & 0x10) !== 0,
    invisible: (value & 0x20) !== 0,
    strikethrough: (value & 0x40) !== 0,
    overline: (value & 0x80) !== 0,
    underline: ((value >> 8) & 0x7) as UnderlineValue,
  };
}

/**
 * Encode a style to 14 bytes
 */
export function encodeStyle(style: Style): Uint8Array {
  const bytes = new Uint8Array(STYLE_BYTE_SIZE);

  // fg_color (bytes 0-3)
  const fg = encodeColor(style.fgColor);
  bytes[0] = fg[0];
  bytes[1] = fg[1];
  bytes[2] = fg[2];
  bytes[3] = fg[3];

  // bg_color (bytes 4-7)
  const bg = encodeColor(style.bgColor);
  bytes[4] = bg[0];
  bytes[5] = bg[1];
  bytes[6] = bg[2];
  bytes[7] = bg[3];

  // underline_color (bytes 8-11)
  const ul = encodeColor(style.underlineColor);
  bytes[8] = ul[0];
  bytes[9] = ul[1];
  bytes[10] = ul[2];
  bytes[11] = ul[3];

  // flags (bytes 12-13, little-endian)
  const flags = encodeFlags(style.flags);
  bytes[12] = flags & 0xff;
  bytes[13] = (flags >> 8) & 0xff;

  return bytes;
}

/**
 * Decode a style from 14 bytes
 */
export function decodeStyle(bytes: Uint8Array, offset: number = 0): Style {
  return {
    fgColor: decodeColor(
      bytes[offset]!,
      bytes[offset + 1]!,
      bytes[offset + 2]!,
      bytes[offset + 3]!
    ),
    bgColor: decodeColor(
      bytes[offset + 4]!,
      bytes[offset + 5]!,
      bytes[offset + 6]!,
      bytes[offset + 7]!
    ),
    underlineColor: decodeColor(
      bytes[offset + 8]!,
      bytes[offset + 9]!,
      bytes[offset + 10]!,
      bytes[offset + 11]!
    ),
    flags: decodeFlags(bytes[offset + 12]! | (bytes[offset + 13]! << 8)),
  };
}

/**
 * Style table: maps style_id to Style.
 * style_id 0 is always the default style.
 */
export type StyleTable = Map<number, Style>;

/**
 * Encode a style table to binary.
 * Format: [count: u16] [id: u16, style: 14 bytes] ...
 */
export function encodeStyleTable(table: StyleTable): Uint8Array {
  const entries = Array.from(table.entries()).filter(([id]) => id > 0);
  const size = 2 + entries.length * (2 + STYLE_BYTE_SIZE);
  const bytes = new Uint8Array(size);
  const view = new DataView(bytes.buffer);

  // Count (excludes default style)
  view.setUint16(0, entries.length, true);

  let offset = 2;
  for (const [id, style] of entries) {
    // Style ID
    view.setUint16(offset, id, true);
    offset += 2;

    // Style data
    const styleBytes = encodeStyle(style);
    bytes.set(styleBytes, offset);
    offset += STYLE_BYTE_SIZE;
  }

  return bytes;
}

/**
 * Decode a style table from binary.
 */
export function decodeStyleTable(bytes: Uint8Array): StyleTable {
  const table: StyleTable = new Map();
  table.set(0, DEFAULT_STYLE);

  if (bytes.length < 2) return table;

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint16(0, true);

  let offset = 2;
  for (let i = 0; i < count; i++) {
    if (offset + 2 + STYLE_BYTE_SIZE > bytes.length) break;

    const id = view.getUint16(offset, true);
    offset += 2;

    const style = decodeStyle(bytes, offset);
    offset += STYLE_BYTE_SIZE;

    table.set(id, style);
  }

  return table;
}

/**
 * Decode a style table from a Uint8Array.
 * Alias for decodeStyleTable for naming consistency.
 */
export const decodeStyleTableFromBytes = decodeStyleTable;

/**
 * Decode a style table from base64.
 */
export function decodeStyleTableFromBase64(base64: string): StyleTable {
  if (!base64) return new Map([[0, DEFAULT_STYLE]]);

  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return decodeStyleTable(bytes);
}

/**
 * Get a style from the table, returning default if not found.
 */
export function getStyle(table: StyleTable, styleId: number): Style {
  return table.get(styleId) ?? DEFAULT_STYLE;
}

/**
 * Check if a style is the default style.
 */
export function isDefaultStyle(style: Style): boolean {
  return (
    style.fgColor.tag === ColorTag.NONE &&
    style.bgColor.tag === ColorTag.NONE &&
    style.underlineColor.tag === ColorTag.NONE &&
    !style.flags.bold &&
    !style.flags.italic &&
    !style.flags.faint &&
    !style.flags.blink &&
    !style.flags.inverse &&
    !style.flags.invisible &&
    !style.flags.strikethrough &&
    !style.flags.overline &&
    style.flags.underline === Underline.NONE
  );
}
