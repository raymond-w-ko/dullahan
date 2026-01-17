/**
 * Tests for cell encoding/decoding.
 */

import { describe, test, expect } from "bun:test";
import {
  Cell,
  ContentTag,
  Wide,
  decodeCell,
  encodeCell,
  decodeCells,
  encodeCells,
  cellToChar,
  decodeCellsFromBase64,
  decodeGraphemes,
} from "./cell";

describe("cell encoding/decoding", () => {
  test("simple ASCII character", () => {
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT, codepoint: 65 }, // 'A'
      styleId: 0,
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.content.tag).toBe(ContentTag.CODEPOINT);
    expect((decoded.content as any).codepoint).toBe(65);
    expect(decoded.styleId).toBe(0);
    expect(decoded.wide).toBe(Wide.NARROW);
    expect(decoded.protected).toBe(false);
    expect(decoded.hyperlink).toBe(false);
    expect(cellToChar(decoded)).toBe("A");
  });

  test("Unicode codepoint (emoji)", () => {
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT, codepoint: 0x1f600 }, // 😀
      styleId: 42,
      wide: Wide.WIDE,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.content.tag).toBe(ContentTag.CODEPOINT);
    expect((decoded.content as any).codepoint).toBe(0x1f600);
    expect(decoded.styleId).toBe(42);
    expect(decoded.wide).toBe(Wide.WIDE);
    expect(cellToChar(decoded)).toBe("😀");
  });

  test("max codepoint (21 bits)", () => {
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT, codepoint: 0x1fffff },
      styleId: 0,
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect((decoded.content as any).codepoint).toBe(0x1fffff);
  });

  test("grapheme cluster marker", () => {
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT_GRAPHEME, codepoint: 0x0301 }, // combining acute
      styleId: 5,
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.content.tag).toBe(ContentTag.CODEPOINT_GRAPHEME);
    expect((decoded.content as any).codepoint).toBe(0x0301);
  });

  test("background color palette", () => {
    const cell: Cell = {
      content: { tag: ContentTag.BG_COLOR_PALETTE, palette: 196 }, // bright red
      styleId: 0,
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.content.tag).toBe(ContentTag.BG_COLOR_PALETTE);
    expect((decoded.content as any).palette).toBe(196);
    expect(cellToChar(decoded)).toBe(" ");
  });

  test("background color RGB", () => {
    const cell: Cell = {
      content: {
        tag: ContentTag.BG_COLOR_RGB,
        rgb: { r: 255, g: 128, b: 64 },
      },
      styleId: 0,
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.content.tag).toBe(ContentTag.BG_COLOR_RGB);
    const rgb = (decoded.content as any).rgb;
    expect(rgb.r).toBe(255);
    expect(rgb.g).toBe(128);
    expect(rgb.b).toBe(64);
  });

  test("style_id spans uint32 boundary", () => {
    // style_id is bits 26-41, so it crosses the lo/hi boundary at bit 32
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT, codepoint: 0 },
      styleId: 0xffff, // max 16-bit value
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.styleId).toBe(0xffff);
  });

  test("style_id various values", () => {
    for (const styleId of [0, 1, 63, 64, 127, 128, 255, 1000, 0x7fff, 0xffff]) {
      const cell: Cell = {
        content: { tag: ContentTag.CODEPOINT, codepoint: 65 },
        styleId,
        wide: Wide.NARROW,
        protected: false,
        hyperlink: false,
      };

      const [lo, hi] = encodeCell(cell);
      const decoded = decodeCell(lo, hi);

      expect(decoded.styleId).toBe(styleId);
    }
  });

  test("wide character states", () => {
    for (const wide of [Wide.NARROW, Wide.WIDE, Wide.SPACER_TAIL, Wide.SPACER_HEAD]) {
      const cell: Cell = {
        content: { tag: ContentTag.CODEPOINT, codepoint: 65 },
        styleId: 0,
        wide,
        protected: false,
        hyperlink: false,
      };

      const [lo, hi] = encodeCell(cell);
      const decoded = decodeCell(lo, hi);

      expect(decoded.wide).toBe(wide);
    }
  });

  test("protected and hyperlink flags", () => {
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT, codepoint: 65 },
      styleId: 0,
      wide: Wide.NARROW,
      protected: true,
      hyperlink: true,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.protected).toBe(true);
    expect(decoded.hyperlink).toBe(true);
  });

  test("empty cell (codepoint 0)", () => {
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT, codepoint: 0 },
      styleId: 0,
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect((decoded.content as any).codepoint).toBe(0);
    expect(cellToChar(decoded)).toBe(" ");
  });

  test("all bits set", () => {
    const cell: Cell = {
      content: { tag: ContentTag.BG_COLOR_RGB, rgb: { r: 255, g: 255, b: 255 } },
      styleId: 0xffff,
      wide: Wide.SPACER_HEAD,
      protected: true,
      hyperlink: true,
    };

    const [lo, hi] = encodeCell(cell);
    const decoded = decodeCell(lo, hi);

    expect(decoded.content.tag).toBe(ContentTag.BG_COLOR_RGB);
    expect((decoded.content as any).rgb).toEqual({ r: 255, g: 255, b: 255 });
    expect(decoded.styleId).toBe(0xffff);
    expect(decoded.wide).toBe(Wide.SPACER_HEAD);
    expect(decoded.protected).toBe(true);
    expect(decoded.hyperlink).toBe(true);
  });
});

describe("bulk cell encoding/decoding", () => {
  test("encode and decode multiple cells", () => {
    const cells: Cell[] = [
      {
        content: { tag: ContentTag.CODEPOINT, codepoint: 72 }, // H
        styleId: 1,
        wide: Wide.NARROW,
        protected: false,
        hyperlink: false,
      },
      {
        content: { tag: ContentTag.CODEPOINT, codepoint: 105 }, // i
        styleId: 2,
        wide: Wide.NARROW,
        protected: false,
        hyperlink: false,
      },
      {
        content: { tag: ContentTag.CODEPOINT, codepoint: 33 }, // !
        styleId: 3,
        wide: Wide.NARROW,
        protected: false,
        hyperlink: true,
      },
    ];

    const buffer = encodeCells(cells);
    expect(buffer.byteLength).toBe(cells.length * 8);

    const decoded = decodeCells(buffer);
    expect(decoded.length).toBe(cells.length);

    expect(cellToChar(decoded[0])).toBe("H");
    expect(cellToChar(decoded[1])).toBe("i");
    expect(cellToChar(decoded[2])).toBe("!");
    expect(decoded[0].styleId).toBe(1);
    expect(decoded[1].styleId).toBe(2);
    expect(decoded[2].styleId).toBe(3);
    expect(decoded[2].hyperlink).toBe(true);
  });

  test("terminal row simulation (80 columns)", () => {
    const cols = 80;
    const cells: Cell[] = [];

    // Create a row with "Hello" at the start, rest empty
    const text = "Hello";
    for (let i = 0; i < cols; i++) {
      cells.push({
        content: {
          tag: ContentTag.CODEPOINT,
          codepoint: i < text.length ? text.charCodeAt(i) : 0,
        },
        styleId: i < text.length ? 1 : 0,
        wide: Wide.NARROW,
        protected: false,
        hyperlink: false,
      });
    }

    const buffer = encodeCells(cells);
    expect(buffer.byteLength).toBe(80 * 8);

    const decoded = decodeCells(buffer);
    const str = decoded.map(cellToChar).join("").trimEnd();
    expect(str).toBe("Hello");
  });

  test("base64 encoding/decoding", () => {
    const cells: Cell[] = [
      {
        content: { tag: ContentTag.CODEPOINT, codepoint: 65 },
        styleId: 0,
        wide: Wide.NARROW,
        protected: false,
        hyperlink: false,
      },
    ];

    const buffer = encodeCells(cells);
    const bytes = new Uint8Array(buffer);
    const base64 = btoa(String.fromCharCode(...bytes));

    const decoded = decodeCellsFromBase64(base64);
    expect(decoded.length).toBe(1);
    expect(cellToChar(decoded[0])).toBe("A");
  });
});

describe("CJK wide character handling", () => {
  test("wide character with spacer", () => {
    // CJK character 中 (U+4E2D) takes 2 cells
    const cells: Cell[] = [
      {
        content: { tag: ContentTag.CODEPOINT, codepoint: 0x4e2d },
        styleId: 0,
        wide: Wide.WIDE,
        protected: false,
        hyperlink: false,
      },
      {
        content: { tag: ContentTag.CODEPOINT, codepoint: 0 },
        styleId: 0,
        wide: Wide.SPACER_TAIL,
        protected: false,
        hyperlink: false,
      },
    ];

    const buffer = encodeCells(cells);
    const decoded = decodeCells(buffer);

    expect(decoded[0].wide).toBe(Wide.WIDE);
    expect(decoded[1].wide).toBe(Wide.SPACER_TAIL);
    expect(cellToChar(decoded[0])).toBe("中");
  });
});

describe("grapheme decoding", () => {
  test("empty grapheme data", () => {
    // Empty data should return empty map
    const graphemes = decodeGraphemes(new Uint8Array([]));
    expect(graphemes.size).toBe(0);

    // Count of 0 should return empty map
    const graphemes2 = decodeGraphemes(new Uint8Array([0, 0, 0, 0]));
    expect(graphemes2.size).toBe(0);
  });

  test("single grapheme entry - thumbs up with skin tone", () => {
    // Thumbs up 👍 (U+1F44D) with skin tone modifier U+1F3FB
    // Binary format: [count: u32 LE] [cell_index: u32 LE, num_cps: u8, cps: 3 bytes LE each]
    const data = new Uint8Array([
      // count = 1
      0x01, 0x00, 0x00, 0x00,
      // cell_index = 5
      0x05, 0x00, 0x00, 0x00,
      // num_codepoints = 1
      0x01,
      // U+1F3FB (skin tone) = 0x01F3FB in little-endian 3 bytes
      0xfb, 0xf3, 0x01,
    ]);

    const graphemes = decodeGraphemes(data);
    expect(graphemes.size).toBe(1);
    expect(graphemes.has(5)).toBe(true);
    expect(graphemes.get(5)).toEqual([0x1f3fb]);
  });

  test("grapheme with multiple extra codepoints - family emoji", () => {
    // Family emoji 👨‍👩‍👧‍👦 is: U+1F468 + ZWJ + U+1F469 + ZWJ + U+1F467 + ZWJ + U+1F466
    // The base codepoint (U+1F468) is in the cell, extras are in grapheme table
    // Extra codepoints: ZWJ (U+200D), U+1F469, ZWJ, U+1F467, ZWJ, U+1F466
    const data = new Uint8Array([
      // count = 1
      0x01, 0x00, 0x00, 0x00,
      // cell_index = 10
      0x0a, 0x00, 0x00, 0x00,
      // num_codepoints = 6
      0x06,
      // ZWJ U+200D
      0x0d, 0x20, 0x00,
      // U+1F469 (woman)
      0x69, 0xf4, 0x01,
      // ZWJ U+200D
      0x0d, 0x20, 0x00,
      // U+1F467 (girl)
      0x67, 0xf4, 0x01,
      // ZWJ U+200D
      0x0d, 0x20, 0x00,
      // U+1F466 (boy)
      0x66, 0xf4, 0x01,
    ]);

    const graphemes = decodeGraphemes(data);
    expect(graphemes.size).toBe(1);
    expect(graphemes.has(10)).toBe(true);
    const cps = graphemes.get(10);
    expect(cps?.length).toBe(6);
    expect(cps).toEqual([0x200d, 0x1f469, 0x200d, 0x1f467, 0x200d, 0x1f466]);
  });

  test("multiple grapheme entries", () => {
    const data = new Uint8Array([
      // count = 2
      0x02, 0x00, 0x00, 0x00,
      // First entry: cell_index = 0, 1 codepoint (skin tone)
      0x00, 0x00, 0x00, 0x00,
      0x01,
      0xfb, 0xf3, 0x01, // U+1F3FB
      // Second entry: cell_index = 20, 1 codepoint (combining acute)
      0x14, 0x00, 0x00, 0x00,
      0x01,
      0x01, 0x03, 0x00, // U+0301 (combining acute accent)
    ]);

    const graphemes = decodeGraphemes(data);
    expect(graphemes.size).toBe(2);
    expect(graphemes.get(0)).toEqual([0x1f3fb]);
    expect(graphemes.get(20)).toEqual([0x0301]);
  });

  test("cellToChar with grapheme data", () => {
    // Create a cell with CODEPOINT_GRAPHEME tag
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT_GRAPHEME, codepoint: 0x1f44d }, // 👍
      styleId: 0,
      wide: Wide.WIDE,
      protected: false,
      hyperlink: false,
    };

    // Grapheme table with skin tone modifier
    const graphemes = new Map<number, number[]>();
    graphemes.set(0, [0x1f3fb]); // Skin tone at cell index 0

    // Without grapheme data, just the base
    expect(cellToChar(cell)).toBe("👍");

    // With grapheme data, combines the codepoints
    const result = cellToChar(cell, graphemes, 0);
    expect(result).toBe("👍🏻");
  });

  test("cellToChar with combining marks", () => {
    // e + combining acute accent = é (decomposed form)
    const cell: Cell = {
      content: { tag: ContentTag.CODEPOINT_GRAPHEME, codepoint: 0x65 }, // 'e'
      styleId: 0,
      wide: Wide.NARROW,
      protected: false,
      hyperlink: false,
    };

    const graphemes = new Map<number, number[]>();
    graphemes.set(5, [0x0301]); // Combining acute at cell index 5

    // Without grapheme, just 'e'
    expect(cellToChar(cell)).toBe("e");

    // With grapheme at different index, still just 'e'
    expect(cellToChar(cell, graphemes, 0)).toBe("e");

    // With grapheme at correct index, combines to 'e' + combining acute
    // String.fromCodePoint(0x65, 0x0301) produces the decomposed form
    const result = cellToChar(cell, graphemes, 5);
    const expected = String.fromCodePoint(0x65, 0x0301); // e + combining acute (NFD form)
    expect(result).toBe(expected);
    expect(result.length).toBe(2); // Two code units: 'e' and combining mark
  });
});
