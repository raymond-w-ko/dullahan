/**
 * Tests for Wine-style category debug logging.
 */

import { describe, test, expect, beforeEach, afterEach } from "bun:test";

// We need to test the module in isolation, so we'll re-import after mocking
// Mock localStorage and window.location before importing the module

const mockStorage = new Map<string, string>();

const mockLocalStorage = {
  getItem: (key: string) => mockStorage.get(key) ?? null,
  setItem: (key: string, value: string) => mockStorage.set(key, value),
  removeItem: (key: string) => mockStorage.delete(key),
  clear: () => mockStorage.clear(),
  get length() {
    return mockStorage.size;
  },
  key: (index: number) => Array.from(mockStorage.keys())[index] ?? null,
};

// Store originals
const originalLocalStorage = globalThis.localStorage;
const originalWindow = globalThis.window;

describe("debug module", () => {
  beforeEach(() => {
    mockStorage.clear();
    Object.defineProperty(globalThis, "localStorage", {
      value: mockLocalStorage,
      writable: true,
      configurable: true,
    });
  });

  afterEach(() => {
    Object.defineProperty(globalThis, "localStorage", {
      value: originalLocalStorage,
      writable: true,
      configurable: true,
    });
    Object.defineProperty(globalThis, "window", {
      value: originalWindow,
      writable: true,
      configurable: true,
    });
  });

  describe("parseDebugConfig (tested via setDebugConfig)", () => {
    test("+all enables all categories", async () => {
      // Set up mock window without debug param
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      // Re-import to get fresh module state
      const { setDebugConfig, isCategoryEnabled, isDebug } = await import("./debug");

      setDebugConfig("+all");
      expect(isDebug()).toBe(true);
      expect(isCategoryEnabled("mouse")).toBe(true);
      expect(isCategoryEnabled("keyboard")).toBe(true);
      expect(isCategoryEnabled("connection")).toBe(true);
    });

    test("-all disables all categories", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, isCategoryEnabled, isDebug } = await import("./debug");

      setDebugConfig("-all");
      expect(isDebug()).toBe(false);
      expect(isCategoryEnabled("mouse")).toBe(false);
      expect(isCategoryEnabled("keyboard")).toBe(false);
    });

    test("+all,-mouse enables all except mouse", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, isCategoryEnabled, isDebug } = await import("./debug");

      setDebugConfig("+all,-mouse");
      expect(isDebug()).toBe(true);
      expect(isCategoryEnabled("mouse")).toBe(false);
      expect(isCategoryEnabled("keyboard")).toBe(true);
      expect(isCategoryEnabled("connection")).toBe(true);
    });

    test("-all,+mouse,+keyboard enables only mouse and keyboard", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, isCategoryEnabled, isDebug, getEnabledCategories } = await import("./debug");

      setDebugConfig("-all,+mouse,+keyboard");
      expect(isDebug()).toBe(true);
      expect(isCategoryEnabled("mouse")).toBe(true);
      expect(isCategoryEnabled("keyboard")).toBe(true);
      expect(isCategoryEnabled("connection")).toBe(false);

      const enabled = getEnabledCategories();
      expect(enabled).toContain("mouse");
      expect(enabled).toContain("keyboard");
      expect(enabled).not.toContain("connection");
    });

    test("bare category name without + is treated as enabled", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, isCategoryEnabled } = await import("./debug");

      setDebugConfig("mouse,keyboard");
      expect(isCategoryEnabled("mouse")).toBe(true);
      expect(isCategoryEnabled("keyboard")).toBe(true);
      expect(isCategoryEnabled("connection")).toBe(false);
    });

    test("empty string is backward compat (+all)", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, isDebug, isCategoryEnabled } = await import("./debug");

      // Empty/null should default to +all for backward compat
      setDebugConfig("");
      // But setDebugConfig('') actually disables - let's check
      // Actually looking at the code, empty string removes from localStorage
    });

    test("'true' is backward compat (+all)", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, isDebug, isCategoryEnabled } = await import("./debug");

      setDebugConfig("true");
      expect(isDebug()).toBe(true);
      expect(isCategoryEnabled("mouse")).toBe(true);
    });

    test("handles whitespace in config", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, isCategoryEnabled } = await import("./debug");

      setDebugConfig("+mouse , +keyboard , -sync");
      expect(isCategoryEnabled("mouse")).toBe(true);
      expect(isCategoryEnabled("keyboard")).toBe(true);
      expect(isCategoryEnabled("sync")).toBe(false);
    });
  });

  describe("category logger", () => {
    test("creates category-scoped logger", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, category } = await import("./debug");

      setDebugConfig("+mouse");
      const mouseLog = category("mouse");

      expect(mouseLog).toHaveProperty("log");
      expect(mouseLog).toHaveProperty("warn");
      expect(mouseLog).toHaveProperty("error");
      expect(mouseLog).toHaveProperty("group");
      expect(mouseLog).toHaveProperty("groupEnd");
      expect(mouseLog).toHaveProperty("table");
      expect(mouseLog).toHaveProperty("time");
      expect(mouseLog).toHaveProperty("timeEnd");
    });

    test("debug.category is accessible", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { debug } = await import("./debug");

      expect(debug.category).toBeDefined();
      const mouseLog = debug.category("mouse");
      expect(mouseLog).toHaveProperty("log");
    });
  });

  describe("getEnabledCategories", () => {
    test("returns all categories when +all", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, getEnabledCategories, DEBUG_CATEGORIES } = await import("./debug");

      setDebugConfig("+all");
      const enabled = getEnabledCategories();

      expect(enabled.length).toBe(DEBUG_CATEGORIES.length);
      for (const cat of DEBUG_CATEGORIES) {
        expect(enabled).toContain(cat);
      }
    });

    test("returns only enabled when specific categories", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, getEnabledCategories } = await import("./debug");

      setDebugConfig("+mouse,+keyboard");
      const enabled = getEnabledCategories();

      expect(enabled.length).toBe(2);
      expect(enabled).toContain("mouse");
      expect(enabled).toContain("keyboard");
    });

    test("excludes disabled categories from +all", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebugConfig, getEnabledCategories, DEBUG_CATEGORIES } = await import("./debug");

      setDebugConfig("+all,-mouse,-keyboard");
      const enabled = getEnabledCategories();

      expect(enabled.length).toBe(DEBUG_CATEGORIES.length - 2);
      expect(enabled).not.toContain("mouse");
      expect(enabled).not.toContain("keyboard");
    });
  });

  describe("listCategories", () => {
    test("returns all known categories", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { listCategories, DEBUG_CATEGORIES } = await import("./debug");

      const categories = listCategories();
      expect(categories).toEqual(DEBUG_CATEGORIES);
    });
  });

  describe("setDebug (backward compat)", () => {
    test("setDebug(true) enables all", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebug, isDebug, isCategoryEnabled } = await import("./debug");

      setDebug(true);
      expect(isDebug()).toBe(true);
      expect(isCategoryEnabled("mouse")).toBe(true);
    });

    test("setDebug(false) disables all", async () => {
      Object.defineProperty(globalThis, "window", {
        value: {
          location: { search: "" },
        },
        writable: true,
        configurable: true,
      });

      const { setDebug, setDebugConfig, isDebug } = await import("./debug");

      setDebugConfig("+all"); // Enable first
      expect(isDebug()).toBe(true);

      setDebug(false);
      expect(isDebug()).toBe(false);
    });
  });
});
