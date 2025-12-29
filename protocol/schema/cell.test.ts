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
