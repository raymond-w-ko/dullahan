/**
 * Cell decoding for dullahan terminal protocol.
 *
 * Decodes raw 64-bit cell data from ghostty-vt into structured cell objects.
 * Each cell is 8 bytes (two uint32 in little-endian).
 *
 * Bit layout (64 bits total):
 *   bits 0-1:   content_tag (2 bits)
 *   bits 2-25:  content (24 bits) - codepoint/palette/RGB
 *   bits 26-41: style_id (16 bits)
 *   bits 42-43: wide (2 bits)
 *   bit 44:     protected (1 bit)
 *   bit 45:     hyperlink (1 bit)
 *   bits 46-63: padding (18 bits)
 */

/** Content type tag */
export const ContentTag = {
  CODEPOINT: 0,
  CODEPOINT_GRAPHEME: 1,
  BG_COLOR_PALETTE: 2,
  BG_COLOR_RGB: 3,
} as const;

export type ContentTagValue = (typeof ContentTag)[keyof typeof ContentTag];

/** Wide character state */
export const Wide = {
  NARROW: 0,
  WIDE: 1,
  SPACER_TAIL: 2,
  SPACER_HEAD: 3,
} as const;

export type WideValue = (typeof Wide)[keyof typeof Wide];

/** RGB color */
export interface RGB {
  r: number;
  g: number;
  b: number;
}

/** Decoded cell content */
export type CellContent =
  | { tag: typeof ContentTag.CODEPOINT; codepoint: number }
  | { tag: typeof ContentTag.CODEPOINT_GRAPHEME; codepoint: number }
  | { tag: typeof ContentTag.BG_COLOR_PALETTE; palette: number }
  | { tag: typeof ContentTag.BG_COLOR_RGB; rgb: RGB };

/** Decoded cell */
export interface Cell {
  content: CellContent;
  styleId: number;
  wide: WideValue;
  protected: boolean;
  hyperlink: boolean;
}

/**
 * Decode a single cell from two uint32 values (lo, hi).
 */
export function decodeCell(lo: number, hi: number): Cell {
  const contentTag = (lo & 0x3) as ContentTagValue;
  const contentBits = (lo >>> 2) & 0xffffff;
  const styleIdLo = (lo >>> 26) & 0x3f;
  const styleIdHi = hi & 0x3ff;
  const styleId = styleIdLo | (styleIdHi << 6);
  const wide = ((hi >>> 10) & 0x3) as WideValue;
  const isProtected = ((hi >>> 12) & 0x1) === 1;
  const isHyperlink = ((hi >>> 13) & 0x1) === 1;

  let content: CellContent;
  switch (contentTag) {
    case ContentTag.CODEPOINT:
      content = { tag: ContentTag.CODEPOINT, codepoint: contentBits & 0x1fffff };
      break;
    case ContentTag.CODEPOINT_GRAPHEME:
      content = { tag: ContentTag.CODEPOINT_GRAPHEME, codepoint: contentBits & 0x1fffff };
      break;
    case ContentTag.BG_COLOR_PALETTE:
      content = { tag: ContentTag.BG_COLOR_PALETTE, palette: contentBits & 0xff };
      break;
    case ContentTag.BG_COLOR_RGB:
      content = {
        tag: ContentTag.BG_COLOR_RGB,
        rgb: {
          r: contentBits & 0xff,
          g: (contentBits >>> 8) & 0xff,
          b: (contentBits >>> 16) & 0xff,
        },
      };
      break;
  }

  return {
    content,
    styleId,
    wide,
    protected: isProtected,
    hyperlink: isHyperlink,
  };
}

/**
 * Decode all cells from a binary buffer.
 * Buffer should be 8 bytes per cell (cols * rows * 8).
 */
export function decodeCells(buffer: ArrayBuffer): Cell[] {
  const view = new Uint32Array(buffer);
  const numCells = view.length / 2;
  const cells: Cell[] = new Array(numCells);

  for (let i = 0; i < numCells; i++) {
    const lo = view[i * 2]!;
    const hi = view[i * 2 + 1]!;
    cells[i] = decodeCell(lo, hi);
  }

  return cells;
}

/**
 * Decode all cells from a Uint8Array.
 * Useful when working with raw byte arrays (e.g., from msgpack).
 */
export function decodeCellsFromBytes(bytes: Uint8Array): Cell[] {
  // Create a new ArrayBuffer with proper alignment
  const buffer = new ArrayBuffer(bytes.length);
  new Uint8Array(buffer).set(bytes);
  return decodeCells(buffer);
}

/**
 * Decode cells from a base64-encoded string.
 */
export function decodeCellsFromBase64(base64: string): Cell[] {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return decodeCells(bytes.buffer);
}

/**
 * Encode a cell to two uint32 values [lo, hi].
 * Useful for testing.
 */
export function encodeCell(cell: Cell): [number, number] {
  let contentTag: number;
  let contentBits: number;

  switch (cell.content.tag) {
    case ContentTag.CODEPOINT:
      contentTag = ContentTag.CODEPOINT;
      contentBits = cell.content.codepoint & 0x1fffff;
      break;
    case ContentTag.CODEPOINT_GRAPHEME:
      contentTag = ContentTag.CODEPOINT_GRAPHEME;
      contentBits = cell.content.codepoint & 0x1fffff;
      break;
    case ContentTag.BG_COLOR_PALETTE:
      contentTag = ContentTag.BG_COLOR_PALETTE;
      contentBits = cell.content.palette & 0xff;
      break;
    case ContentTag.BG_COLOR_RGB:
      contentTag = ContentTag.BG_COLOR_RGB;
      contentBits =
        (cell.content.rgb.r & 0xff) |
        ((cell.content.rgb.g & 0xff) << 8) |
        ((cell.content.rgb.b & 0xff) << 16);
      break;
  }

  const styleIdLo = cell.styleId & 0x3f;
  const styleIdHi = (cell.styleId >>> 6) & 0x3ff;

  const lo = contentTag | (contentBits << 2) | (styleIdLo << 26);
  const hi =
    styleIdHi |
    ((cell.wide & 0x3) << 10) |
    ((cell.protected ? 1 : 0) << 12) |
    ((cell.hyperlink ? 1 : 0) << 13);

  return [lo >>> 0, hi >>> 0]; // Ensure unsigned
}

/**
 * Encode cells to a binary buffer.
 */
export function encodeCells(cells: Cell[]): ArrayBuffer {
  const buffer = new ArrayBuffer(cells.length * 8);
  const view = new Uint32Array(buffer);

  for (let i = 0; i < cells.length; i++) {
    const [lo, hi] = encodeCell(cells[i]!);
    view[i * 2] = lo;
    view[i * 2 + 1] = hi;
  }

  return buffer;
}

/** Grapheme table: maps cell index to additional codepoints */
export type GraphemeTable = Map<number, number[]>;

/** Hyperlink table: maps cell index to URL string */
export type HyperlinkTable = Map<number, string>;

/**
 * Decode hyperlink table from binary format.
 *
 * Binary format:
 * [count: u32 LE]
 * For each entry:
 *   [cell_index: u32 LE]
 *   [url_len: u16 LE]
 *   [url: url_len bytes UTF-8]
 *
 * @param data - The binary hyperlink data
 * @returns Map from cell index to URL string
 */
export function decodeHyperlinks(data: Uint8Array): HyperlinkTable {
  const hyperlinks: HyperlinkTable = new Map();

  if (!data || data.length < 4) {
    return hyperlinks;
  }

  // Read count (u32 LE)
  const count =
    (data[0] ?? 0) |
    ((data[1] ?? 0) << 8) |
    ((data[2] ?? 0) << 16) |
    ((data[3] ?? 0) << 24);

  let offset = 4;
  for (let i = 0; i < count && offset + 6 <= data.length; i++) {
    // Read cell index (u32 LE)
    const cellIndex =
      (data[offset] ?? 0) |
      ((data[offset + 1] ?? 0) << 8) |
      ((data[offset + 2] ?? 0) << 16) |
      ((data[offset + 3] ?? 0) << 24);
    offset += 4;

    // Read URL length (u16 LE)
    const urlLen = (data[offset] ?? 0) | ((data[offset + 1] ?? 0) << 8);
    offset += 2;

    // Bounds check for URL
    if (offset + urlLen > data.length) {
      break;
    }

    // Read URL bytes and decode as UTF-8
    const urlBytes = data.slice(offset, offset + urlLen);
    const url = new TextDecoder().decode(urlBytes);
    offset += urlLen;

    if (url.length > 0) {
      hyperlinks.set(cellIndex, url);
    }
  }

  return hyperlinks;
}

/**
 * Decode grapheme table from binary format.
 *
 * Binary format:
 * [count: u32 LE]
 * For each entry:
 *   [cell_index: u32 LE]
 *   [num_codepoints: u8]
 *   [codepoints: 3 bytes LE per u21]...
 *
 * @param data - The binary grapheme data
 * @returns Map from cell index to array of additional codepoints
 */
export function decodeGraphemes(data: Uint8Array): GraphemeTable {
  const graphemes: GraphemeTable = new Map();

  if (!data || data.length < 4) {
    return graphemes;
  }

  // Read count (u32 LE)
  const count =
    (data[0] ?? 0) |
    ((data[1] ?? 0) << 8) |
    ((data[2] ?? 0) << 16) |
    ((data[3] ?? 0) << 24);

  let offset = 4;
  for (let i = 0; i < count && offset + 5 <= data.length; i++) {
    // Read cell index (u32 LE)
    const cellIndex =
      (data[offset] ?? 0) |
      ((data[offset + 1] ?? 0) << 8) |
      ((data[offset + 2] ?? 0) << 16) |
      ((data[offset + 3] ?? 0) << 24);
    offset += 4;

    // Read number of codepoints (u8)
    const numCodepoints = data[offset] ?? 0;
    offset += 1;

    // Read codepoints (3 bytes each, LE)
    const codepoints: number[] = [];
    for (let j = 0; j < numCodepoints && offset + 3 <= data.length; j++) {
      const cp =
        (data[offset] ?? 0) |
        ((data[offset + 1] ?? 0) << 8) |
        ((data[offset + 2] ?? 0) << 16);
      codepoints.push(cp);
      offset += 3;
    }

    if (codepoints.length > 0) {
      graphemes.set(cellIndex, codepoints);
    }
  }

  return graphemes;
}

/**
 * Get the character for a cell, or empty string if no text.
 * If grapheme data is provided, combines the base codepoint with additional codepoints.
 *
 * @param cell - The cell to get the character from
 * @param graphemes - Optional grapheme table (maps cell index to additional codepoints)
 * @param cellIndex - Cell index for grapheme lookup (required if graphemes is provided)
 */
export function cellToChar(
  cell: Cell,
  graphemes?: GraphemeTable,
  cellIndex?: number
): string {
  if (
    cell.content.tag === ContentTag.CODEPOINT ||
    cell.content.tag === ContentTag.CODEPOINT_GRAPHEME
  ) {
    const cp = cell.content.codepoint;
    if (cp === 0) return " ";

    // If this is a grapheme cell and we have grapheme data, combine codepoints
    if (
      cell.content.tag === ContentTag.CODEPOINT_GRAPHEME &&
      graphemes &&
      cellIndex !== undefined
    ) {
      const extraCps = graphemes.get(cellIndex);
      if (extraCps && extraCps.length > 0) {
        // Combine base codepoint with additional codepoints
        return String.fromCodePoint(cp, ...extraCps);
      }
    }

    return String.fromCodePoint(cp);
  }
  return " ";
}
