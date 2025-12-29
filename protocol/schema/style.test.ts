/**
 * Tests for style encoding/decoding.
 */

import { describe, test, expect } from "bun:test";
import {
  Style,
  StyleFlags,
  Color,
  ColorTag,
  Underline,
  DEFAULT_STYLE,
  STYLE_BYTE_SIZE,
  encodeColor,
  decodeColor,
  encodeFlags,
  decodeFlags,
  encodeStyle,
  decodeStyle,
  encodeStyleTable,
  decodeStyleTable,
  decodeStyleTableFromBase64,
  getStyle,
  isDefaultStyle,
} from "./style";

describe("color encoding/decoding", () => {
  test("none color", () => {
    const color: Color = { tag: ColorTag.NONE };
    const encoded = encodeColor(color);
    expect(encoded).toEqual([0, 0, 0, 0]);

    const decoded = decodeColor(encoded[0], encoded[1], encoded[2], encoded[3]);
    expect(decoded.tag).toBe(ColorTag.NONE);
  });

  test("palette color", () => {
    const color: Color = { tag: ColorTag.PALETTE, index: 196 };
    const encoded = encodeColor(color);
    expect(encoded).toEqual([1, 196, 0, 0]);

    const decoded = decodeColor(encoded[0], encoded[1], encoded[2], encoded[3]);
    expect(decoded.tag).toBe(ColorTag.PALETTE);
    expect((decoded as any).index).toBe(196);
  });

  test("RGB color", () => {
    const color: Color = { tag: ColorTag.RGB, r: 255, g: 128, b: 64 };
    const encoded = encodeColor(color);
    expect(encoded).toEqual([2, 255, 128, 64]);

    const decoded = decodeColor(encoded[0], encoded[1], encoded[2], encoded[3]);
    expect(decoded.tag).toBe(ColorTag.RGB);
    expect((decoded as any).r).toBe(255);
    expect((decoded as any).g).toBe(128);
    expect((decoded as any).b).toBe(64);
  });

  test("palette index 0", () => {
    const color: Color = { tag: ColorTag.PALETTE, index: 0 };
    const encoded = encodeColor(color);
    const decoded = decodeColor(encoded[0], encoded[1], encoded[2], encoded[3]);
    expect(decoded.tag).toBe(ColorTag.PALETTE);
    expect((decoded as any).index).toBe(0);
  });

  test("palette index 255", () => {
    const color: Color = { tag: ColorTag.PALETTE, index: 255 };
    const encoded = encodeColor(color);
    const decoded = decodeColor(encoded[0], encoded[1], encoded[2], encoded[3]);
    expect(decoded.tag).toBe(ColorTag.PALETTE);
    expect((decoded as any).index).toBe(255);
  });
});

describe("flags encoding/decoding", () => {
  test("all flags off", () => {
    const flags: StyleFlags = {
      bold: false,
      italic: false,
      faint: false,
      blink: false,
      inverse: false,
      invisible: false,
      strikethrough: false,
      overline: false,
      underline: Underline.NONE,
    };
    const encoded = encodeFlags(flags);
    expect(encoded).toBe(0);

    const decoded = decodeFlags(encoded);
    expect(decoded).toEqual(flags);
  });

  test("bold only", () => {
    const flags: StyleFlags = {
      bold: true,
      italic: false,
      faint: false,
      blink: false,
      inverse: false,
      invisible: false,
      strikethrough: false,
      overline: false,
      underline: Underline.NONE,
    };
    const encoded = encodeFlags(flags);
    expect(encoded).toBe(0x01);

    const decoded = decodeFlags(encoded);
    expect(decoded.bold).toBe(true);
    expect(decoded.italic).toBe(false);
  });

  test("all flags on", () => {
    const flags: StyleFlags = {
      bold: true,
      italic: true,
      faint: true,
      blink: true,
      inverse: true,
      invisible: true,
      strikethrough: true,
      overline: true,
      underline: Underline.CURLY,
    };
    const encoded = encodeFlags(flags);

    const decoded = decodeFlags(encoded);
    expect(decoded).toEqual(flags);
  });

  test("underline styles", () => {
    for (const underline of [
      Underline.NONE,
      Underline.SINGLE,
      Underline.DOUBLE,
      Underline.CURLY,
      Underline.DOTTED,
      Underline.DASHED,
    ]) {
      const flags: StyleFlags = {
        bold: false,
        italic: false,
        faint: false,
        blink: false,
        inverse: false,
        invisible: false,
        strikethrough: false,
        overline: false,
        underline,
      };
      const encoded = encodeFlags(flags);
      const decoded = decodeFlags(encoded);
      expect(decoded.underline).toBe(underline);
    }
  });
});

describe("style encoding/decoding", () => {
  test("default style", () => {
    const encoded = encodeStyle(DEFAULT_STYLE);
    expect(encoded.length).toBe(STYLE_BYTE_SIZE);
    expect(encoded.every((b) => b === 0)).toBe(true);

    const decoded = decodeStyle(encoded);
    expect(isDefaultStyle(decoded)).toBe(true);
  });

  test("style with RGB fg", () => {
    const style: Style = {
      fgColor: { tag: ColorTag.RGB, r: 255, g: 0, b: 0 },
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

    const encoded = encodeStyle(style);
    const decoded = decodeStyle(encoded);

    expect(decoded.fgColor.tag).toBe(ColorTag.RGB);
    expect((decoded.fgColor as any).r).toBe(255);
    expect((decoded.fgColor as any).g).toBe(0);
    expect((decoded.fgColor as any).b).toBe(0);
  });

  test("style with palette bg", () => {
    const style: Style = {
      fgColor: { tag: ColorTag.NONE },
      bgColor: { tag: ColorTag.PALETTE, index: 21 },
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

    const encoded = encodeStyle(style);
    const decoded = decodeStyle(encoded);

    expect(decoded.bgColor.tag).toBe(ColorTag.PALETTE);
    expect((decoded.bgColor as any).index).toBe(21);
  });

  test("style with bold and italic", () => {
    const style: Style = {
      fgColor: { tag: ColorTag.NONE },
      bgColor: { tag: ColorTag.NONE },
      underlineColor: { tag: ColorTag.NONE },
      flags: {
        bold: true,
        italic: true,
        faint: false,
        blink: false,
        inverse: false,
        invisible: false,
        strikethrough: false,
        overline: false,
        underline: Underline.NONE,
      },
    };

    const encoded = encodeStyle(style);
    const decoded = decodeStyle(encoded);

    expect(decoded.flags.bold).toBe(true);
    expect(decoded.flags.italic).toBe(true);
    expect(decoded.flags.faint).toBe(false);
  });

  test("style with underline color", () => {
    const style: Style = {
      fgColor: { tag: ColorTag.NONE },
      bgColor: { tag: ColorTag.NONE },
      underlineColor: { tag: ColorTag.RGB, r: 255, g: 165, b: 0 },
      flags: {
        bold: false,
        italic: false,
        faint: false,
        blink: false,
        inverse: false,
        invisible: false,
        strikethrough: false,
        overline: false,
        underline: Underline.CURLY,
      },
    };

    const encoded = encodeStyle(style);
    const decoded = decodeStyle(encoded);

    expect(decoded.underlineColor.tag).toBe(ColorTag.RGB);
    expect((decoded.underlineColor as any).r).toBe(255);
    expect((decoded.underlineColor as any).g).toBe(165);
    expect((decoded.underlineColor as any).b).toBe(0);
    expect(decoded.flags.underline).toBe(Underline.CURLY);
  });

  test("complex style", () => {
    const style: Style = {
      fgColor: { tag: ColorTag.RGB, r: 200, g: 200, b: 200 },
      bgColor: { tag: ColorTag.PALETTE, index: 17 },
      underlineColor: { tag: ColorTag.RGB, r: 255, g: 0, b: 255 },
      flags: {
        bold: true,
        italic: false,
        faint: false,
        blink: true,
        inverse: false,
        invisible: false,
        strikethrough: true,
        overline: false,
        underline: Underline.DOUBLE,
      },
    };

    const encoded = encodeStyle(style);
    expect(encoded.length).toBe(STYLE_BYTE_SIZE);

    const decoded = decodeStyle(encoded);

    expect(decoded.fgColor).toEqual(style.fgColor);
    expect(decoded.bgColor).toEqual(style.bgColor);
    expect(decoded.underlineColor).toEqual(style.underlineColor);
    expect(decoded.flags).toEqual(style.flags);
  });
});

describe("style table encoding/decoding", () => {
  test("empty table (default only)", () => {
    const table = new Map<number, Style>();
    table.set(0, DEFAULT_STYLE);

    const encoded = encodeStyleTable(table);
    expect(encoded.length).toBe(2); // Just the count

    const decoded = decodeStyleTable(encoded);
    expect(decoded.size).toBe(1);
    expect(isDefaultStyle(decoded.get(0)!)).toBe(true);
  });

  test("table with one custom style", () => {
    const style: Style = {
      fgColor: { tag: ColorTag.RGB, r: 255, g: 0, b: 0 },
      bgColor: { tag: ColorTag.NONE },
      underlineColor: { tag: ColorTag.NONE },
      flags: { ...DEFAULT_STYLE.flags, bold: true },
    };

    const table = new Map<number, Style>();
    table.set(0, DEFAULT_STYLE);
    table.set(1, style);

    const encoded = encodeStyleTable(table);
    expect(encoded.length).toBe(2 + 2 + STYLE_BYTE_SIZE); // count + id + style

    const decoded = decodeStyleTable(encoded);
    expect(decoded.size).toBe(2);
    expect(decoded.get(1)?.fgColor.tag).toBe(ColorTag.RGB);
    expect(decoded.get(1)?.flags.bold).toBe(true);
  });

  test("table with multiple styles", () => {
    const table = new Map<number, Style>();
    table.set(0, DEFAULT_STYLE);
    table.set(1, {
      fgColor: { tag: ColorTag.PALETTE, index: 1 },
      bgColor: { tag: ColorTag.NONE },
      underlineColor: { tag: ColorTag.NONE },
      flags: DEFAULT_STYLE.flags,
    });
    table.set(42, {
      fgColor: { tag: ColorTag.RGB, r: 100, g: 150, b: 200 },
      bgColor: { tag: ColorTag.PALETTE, index: 0 },
      underlineColor: { tag: ColorTag.NONE },
      flags: { ...DEFAULT_STYLE.flags, italic: true },
    });

    const encoded = encodeStyleTable(table);
    const decoded = decodeStyleTable(encoded);

    expect(decoded.size).toBe(3); // default + 2 custom
    expect(decoded.get(1)?.fgColor.tag).toBe(ColorTag.PALETTE);
    expect(decoded.get(42)?.fgColor.tag).toBe(ColorTag.RGB);
    expect(decoded.get(42)?.flags.italic).toBe(true);
  });

  test("base64 round-trip", () => {
    const table = new Map<number, Style>();
    table.set(0, DEFAULT_STYLE);
    table.set(5, {
      fgColor: { tag: ColorTag.RGB, r: 128, g: 128, b: 128 },
      bgColor: { tag: ColorTag.NONE },
      underlineColor: { tag: ColorTag.NONE },
      flags: DEFAULT_STYLE.flags,
    });

    const encoded = encodeStyleTable(table);
    const base64 = btoa(String.fromCharCode(...encoded));

    const decoded = decodeStyleTableFromBase64(base64);
    expect(decoded.size).toBe(2);
    expect(decoded.get(5)?.fgColor.tag).toBe(ColorTag.RGB);
  });

  test("empty base64 returns default table", () => {
    const decoded = decodeStyleTableFromBase64("");
    expect(decoded.size).toBe(1);
    expect(decoded.has(0)).toBe(true);
  });
});

describe("utility functions", () => {
  test("getStyle returns default for missing id", () => {
    const table = new Map<number, Style>();
    table.set(0, DEFAULT_STYLE);

    const style = getStyle(table, 999);
    expect(isDefaultStyle(style)).toBe(true);
  });

  test("getStyle returns style for existing id", () => {
    const customStyle: Style = {
      fgColor: { tag: ColorTag.RGB, r: 1, g: 2, b: 3 },
      bgColor: { tag: ColorTag.NONE },
      underlineColor: { tag: ColorTag.NONE },
      flags: DEFAULT_STYLE.flags,
    };

    const table = new Map<number, Style>();
    table.set(0, DEFAULT_STYLE);
    table.set(10, customStyle);

    const style = getStyle(table, 10);
    expect(style.fgColor.tag).toBe(ColorTag.RGB);
  });

  test("isDefaultStyle detects default", () => {
    expect(isDefaultStyle(DEFAULT_STYLE)).toBe(true);
  });

  test("isDefaultStyle detects non-default", () => {
    const style: Style = {
      ...DEFAULT_STYLE,
      flags: { ...DEFAULT_STYLE.flags, bold: true },
    };
    expect(isDefaultStyle(style)).toBe(false);
  });
});
