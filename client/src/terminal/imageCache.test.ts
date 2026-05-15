import { afterEach, expect, test } from "bun:test";
import {
  cacheTerminalImageUrl,
  clearTerminalImageCache,
  getCachedTerminalImageUrl,
} from "./imageCache";

afterEach(() => {
  clearTerminalImageCache();
});

test("terminal image cache returns cached object URL", () => {
  cacheTerminalImageUrl("key", "blob:one");
  expect(getCachedTerminalImageUrl("key")).toBe("blob:one");
});

test("terminal image cache revokes duplicate object URLs", () => {
  const original = URL.revokeObjectURL;
  const revoked: string[] = [];
  URL.revokeObjectURL = (url: string) => {
    revoked.push(url);
  };
  try {
    cacheTerminalImageUrl("key", "blob:one");
    cacheTerminalImageUrl("key", "blob:two");
    expect(getCachedTerminalImageUrl("key")).toBe("blob:one");
    expect(revoked).toEqual(["blob:two"]);
  } finally {
    URL.revokeObjectURL = original;
  }
});
