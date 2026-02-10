import { describe, expect, test } from "bun:test";

import type { Cell } from "../../../protocol/schema/cell";
import { ContentTag, Wide } from "../../../protocol/schema/cell";
import { ColorTag, DEFAULT_STYLE, Underline } from "../../../protocol/schema/style";
import type { Style, StyleTable } from "../../../protocol/schema/style";

import {
  canonicalizePayloadStyles,
  createStyleIdentityState,
  pruneUnusedStyles,
  remapCellsToCanonicalStyles,
} from "./styleIdentity";

function makeStyle(opts: Partial<Style> = {}): Style {
  return {
    fgColor: opts.fgColor ?? { tag: ColorTag.NONE },
    bgColor: opts.bgColor ?? { tag: ColorTag.NONE },
    underlineColor: opts.underlineColor ?? { tag: ColorTag.NONE },
    flags: opts.flags ?? {
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
}

function makeCell(styleId: number): Cell {
  return {
    content: { tag: ContentTag.CODEPOINT, codepoint: 65 },
    styleId,
    wide: Wide.NARROW,
    protected: false,
    hyperlink: false,
  };
}

describe("style identity canonicalization", () => {
  test("deduplicates identical styles across payload IDs", () => {
    const styleA = makeStyle({ fgColor: { tag: ColorTag.PALETTE, index: 2 } });
    const styleB = makeStyle({
      fgColor: { tag: ColorTag.RGB, r: 10, g: 20, b: 30 },
      flags: { ...DEFAULT_STYLE.flags, bold: true },
    });

    const payload: StyleTable = new Map([
      [0, DEFAULT_STYLE],
      [7, styleA],
      [9, styleA],
      [11, styleB],
    ]);

    const styles: StyleTable = new Map([[0, DEFAULT_STYLE]]);
    const identity = createStyleIdentityState();
    const remap = canonicalizePayloadStyles(payload, styles, identity);

    expect(remap.get(7)).toBe(remap.get(9));
    expect(remap.get(7)).not.toBe(remap.get(11));
    expect(styles.size).toBe(3); // default + styleA + styleB
  });

  test("reused payload ID with different style gets a new canonical ID", () => {
    const styleA = makeStyle({ fgColor: { tag: ColorTag.PALETTE, index: 3 } });
    const styleB = makeStyle({ fgColor: { tag: ColorTag.PALETTE, index: 4 } });

    const styles: StyleTable = new Map([[0, DEFAULT_STYLE]]);
    const identity = createStyleIdentityState();

    const remap1 = canonicalizePayloadStyles(
      new Map([
        [0, DEFAULT_STYLE],
        [7, styleA],
      ]),
      styles,
      identity,
    );
    const remap2 = canonicalizePayloadStyles(
      new Map([
        [0, DEFAULT_STYLE],
        [7, styleB],
      ]),
      styles,
      identity,
    );

    const idA = remap1.get(7);
    const idB = remap2.get(7);

    expect(idA).toBeDefined();
    expect(idB).toBeDefined();
    expect(idA).not.toBe(idB);
    expect(styles.get(idA!)).toEqual(styleA);
    expect(styles.get(idB!)).toEqual(styleB);
  });

  test("remaps cells and reports missing payload mappings", () => {
    const cells = [makeCell(7), makeCell(8), makeCell(0)];
    const missing = remapCellsToCanonicalStyles(cells, new Map([[7, 42]]));

    expect(missing).toBe(1);
    expect(cells[0]?.styleId).toBe(42);
    expect(cells[1]?.styleId).toBe(8);
    expect(cells[2]?.styleId).toBe(0);
  });

  test("pruning removes unused canonical style IDs and identity map entries", () => {
    const styleA = makeStyle({ fgColor: { tag: ColorTag.PALETTE, index: 1 } });
    const styleB = makeStyle({ fgColor: { tag: ColorTag.PALETTE, index: 5 } });

    const styles: StyleTable = new Map([[0, DEFAULT_STYLE]]);
    const identity = createStyleIdentityState();
    const remap = canonicalizePayloadStyles(
      new Map([
        [0, DEFAULT_STYLE],
        [1, styleA],
        [2, styleB],
      ]),
      styles,
      identity,
    );

    const keepId = remap.get(1)!;
    const dropId = remap.get(2)!;

    pruneUnusedStyles(styles, identity, new Set([keepId]));

    expect(styles.has(keepId)).toBe(true);
    expect(styles.has(dropId)).toBe(false);
    expect(identity.idToKey.has(dropId)).toBe(false);
  });
});
