import { expect, test } from "bun:test";
import { resolveTerminalImageZIndex } from "./imageZIndex";

test("resolveTerminalImageZIndex preserves Kitty z ordering", () => {
  expect(resolveTerminalImageZIndex(1)).toBeGreaterThan(resolveTerminalImageZIndex(0));
  expect(resolveTerminalImageZIndex(0)).toBeGreaterThan(resolveTerminalImageZIndex(-1));
});

test("resolveTerminalImageZIndex clamps unsafe values", () => {
  expect(resolveTerminalImageZIndex(Number.POSITIVE_INFINITY)).toBe(1000);
  expect(resolveTerminalImageZIndex(-5000)).toBe(0);
});
