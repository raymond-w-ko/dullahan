import { describe, expect, test } from "bun:test";

import { resolveRenderedCursorStyle } from "./cursorStyle";

describe("resolveRenderedCursorStyle", () => {
  test("preserves configured hollow block when server reports block", () => {
    expect(resolveRenderedCursorStyle("block_hollow", "block")).toBe("block_hollow");
  });

  test("uses server bar style over local config", () => {
    expect(resolveRenderedCursorStyle("block", "bar")).toBe("bar");
    expect(resolveRenderedCursorStyle("block_hollow", "bar")).toBe("bar");
  });

  test("uses server underline style over local config", () => {
    expect(resolveRenderedCursorStyle("block", "underline")).toBe("underline");
    expect(resolveRenderedCursorStyle("block_hollow", "underline")).toBe("underline");
  });

  test("keeps normal block when both sides are block", () => {
    expect(resolveRenderedCursorStyle("block", "block")).toBe("block");
  });
});
