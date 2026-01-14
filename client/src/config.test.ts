/**
 * Tests for client configuration system.
 */

import { describe, test, expect, beforeEach, afterEach, mock, spyOn } from "bun:test";
import {
  parseBellFeatures,
  getBellFeatures,
  get,
  set,
  remove,
  isSet,
  getAll,
  DEFAULTS,
  type ConfigKey,
  type BellFeatureFlags,
} from "./config";

// Mock localStorage
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

// Store original localStorage
const originalLocalStorage = globalThis.localStorage;

// Mock window for event dispatching
const dispatchedEvents: CustomEvent[] = [];
const mockWindow = {
  dispatchEvent: (event: CustomEvent) => {
    dispatchedEvents.push(event);
    return true;
  },
  addEventListener: () => {},
  removeEventListener: () => {},
};

const originalWindow = globalThis.window;

beforeEach(() => {
  mockStorage.clear();
  dispatchedEvents.length = 0;
  Object.defineProperty(globalThis, "localStorage", {
    value: mockLocalStorage,
    writable: true,
    configurable: true,
  });
  Object.defineProperty(globalThis, "window", {
    value: mockWindow,
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

describe("parseBellFeatures", () => {
  test("parses all features enabled", () => {
    const flags = parseBellFeatures("audio,attention,title");
    expect(flags.audio).toBe(true);
    expect(flags.attention).toBe(true);
    expect(flags.title).toBe(true);
  });

  test("parses single feature", () => {
    expect(parseBellFeatures("audio")).toEqual({
      audio: true,
      attention: false,
      title: false,
    });
    expect(parseBellFeatures("attention")).toEqual({
      audio: false,
      attention: true,
      title: false,
    });
    expect(parseBellFeatures("title")).toEqual({
      audio: false,
      attention: false,
      title: true,
    });
  });

  test("parses two features", () => {
    const flags = parseBellFeatures("audio,title");
    expect(flags.audio).toBe(true);
    expect(flags.attention).toBe(false);
    expect(flags.title).toBe(true);
  });

  test("handles whitespace", () => {
    const flags = parseBellFeatures("audio , attention , title");
    expect(flags.audio).toBe(true);
    expect(flags.attention).toBe(true);
    expect(flags.title).toBe(true);
  });

  test("handles case insensitivity", () => {
    const flags = parseBellFeatures("AUDIO,Attention,TITLE");
    expect(flags.audio).toBe(true);
    expect(flags.attention).toBe(true);
    expect(flags.title).toBe(true);
  });

  test("handles empty string", () => {
    const flags = parseBellFeatures("");
    expect(flags.audio).toBe(false);
    expect(flags.attention).toBe(false);
    expect(flags.title).toBe(false);
  });

  test("ignores unknown features", () => {
    const flags = parseBellFeatures("audio,unknown,title");
    expect(flags.audio).toBe(true);
    expect(flags.attention).toBe(false);
    expect(flags.title).toBe(true);
  });

  test("handles duplicate features", () => {
    const flags = parseBellFeatures("audio,audio,audio");
    expect(flags.audio).toBe(true);
    expect(flags.attention).toBe(false);
    expect(flags.title).toBe(false);
  });
});

describe("get", () => {
  test("returns default when not set", () => {
    expect(get("theme")).toBe(DEFAULTS.theme);
    expect(get("fontSize")).toBe(DEFAULTS.fontSize);
    expect(get("selectionClearOnCopy")).toBe(DEFAULTS.selectionClearOnCopy);
  });

  test("returns stored string value", () => {
    mockStorage.set("dullahan.theme", "gruvbox-dark");
    expect(get("theme")).toBe("gruvbox-dark");
  });

  test("returns stored number value", () => {
    mockStorage.set("dullahan.fontSize", "16");
    expect(get("fontSize")).toBe(16);
  });

  test("returns stored boolean value", () => {
    mockStorage.set("dullahan.selectionClearOnCopy", "false");
    expect(get("selectionClearOnCopy")).toBe(false);

    mockStorage.set("dullahan.selectionClearOnCopy", "true");
    expect(get("selectionClearOnCopy")).toBe(true);
  });

  test("returns default for invalid number", () => {
    mockStorage.set("dullahan.fontSize", "not-a-number");
    expect(get("fontSize")).toBe(DEFAULTS.fontSize);
  });

  test("uses custom fallback when provided", () => {
    expect(get("theme", "custom-theme")).toBe("custom-theme");
  });

  test("stored value takes precedence over fallback", () => {
    mockStorage.set("dullahan.theme", "stored-theme");
    expect(get("theme", "fallback-theme")).toBe("stored-theme");
  });

  test("handles float numbers", () => {
    mockStorage.set("dullahan.lineHeight", "1.5");
    expect(get("lineHeight")).toBe(1.5);
  });

  test("handles negative numbers", () => {
    mockStorage.set("dullahan.adjustCellWidth", "-2");
    expect(get("adjustCellWidth")).toBe(-2);
  });
});

describe("set", () => {
  test("stores string value", () => {
    set("theme", "nord");
    expect(mockStorage.get("dullahan.theme")).toBe("nord");
  });

  test("stores number value as string", () => {
    set("fontSize", 18);
    expect(mockStorage.get("dullahan.fontSize")).toBe("18");
  });

  test("stores boolean value as string", () => {
    set("selectionClearOnCopy", false);
    expect(mockStorage.get("dullahan.selectionClearOnCopy")).toBe("false");
  });

  test("dispatches config-change event", () => {
    set("theme", "dracula");

    expect(dispatchedEvents.length).toBe(1);
    expect(dispatchedEvents[0].type).toBe("config-change");
    expect(dispatchedEvents[0].detail).toEqual({
      key: "theme",
      value: "dracula",
    });
  });

  test("stores float numbers", () => {
    set("lineHeight", 1.35);
    expect(mockStorage.get("dullahan.lineHeight")).toBe("1.35");
  });
});

describe("remove", () => {
  test("removes stored value", () => {
    mockStorage.set("dullahan.theme", "custom");
    remove("theme");
    expect(mockStorage.has("dullahan.theme")).toBe(false);
  });

  test("dispatches config-change event with default value", () => {
    mockStorage.set("dullahan.theme", "custom");
    remove("theme");

    expect(dispatchedEvents.length).toBe(1);
    expect(dispatchedEvents[0].detail).toEqual({
      key: "theme",
      value: DEFAULTS.theme,
    });
  });
});

describe("isSet", () => {
  test("returns false when not set", () => {
    expect(isSet("theme")).toBe(false);
  });

  test("returns true when set", () => {
    mockStorage.set("dullahan.theme", "custom");
    expect(isSet("theme")).toBe(true);
  });

  test("returns false after removal", () => {
    mockStorage.set("dullahan.theme", "custom");
    mockStorage.delete("dullahan.theme");
    expect(isSet("theme")).toBe(false);
  });
});

describe("getAll", () => {
  test("returns all defaults when nothing set", () => {
    const all = getAll();
    expect(all.theme).toBe(DEFAULTS.theme);
    expect(all.fontSize).toBe(DEFAULTS.fontSize);
    expect(all.cursorStyle).toBe(DEFAULTS.cursorStyle);
  });

  test("returns mix of stored and default values", () => {
    mockStorage.set("dullahan.theme", "nord");
    mockStorage.set("dullahan.fontSize", "16");

    const all = getAll();
    expect(all.theme).toBe("nord");
    expect(all.fontSize).toBe(16);
    expect(all.cursorStyle).toBe(DEFAULTS.cursorStyle); // Still default
  });

  test("returns all config keys", () => {
    const all = getAll();
    const defaultKeys = Object.keys(DEFAULTS);
    const allKeys = Object.keys(all);

    expect(allKeys.sort()).toEqual(defaultKeys.sort());
  });
});

describe("getBellFeatures", () => {
  test("returns parsed default bell features", () => {
    const features = getBellFeatures();
    // Default is "audio,attention,title"
    expect(features.audio).toBe(true);
    expect(features.attention).toBe(true);
    expect(features.title).toBe(true);
  });

  test("returns parsed stored bell features", () => {
    mockStorage.set("dullahan.bellFeatures", "audio");
    const features = getBellFeatures();
    expect(features.audio).toBe(true);
    expect(features.attention).toBe(false);
    expect(features.title).toBe(false);
  });
});

describe("DEFAULTS", () => {
  test("has all required keys", () => {
    expect(DEFAULTS.theme).toBeDefined();
    expect(DEFAULTS.fontSize).toBeDefined();
    expect(DEFAULTS.fontFamily).toBeDefined();
    expect(DEFAULTS.cursorStyle).toBeDefined();
    expect(DEFAULTS.bellFeatures).toBeDefined();
  });

  test("has valid cursor style", () => {
    const validStyles = ["block", "bar", "underline", "block_hollow"];
    expect(validStyles).toContain(DEFAULTS.cursorStyle);
  });

  test("has valid spacing", () => {
    const validSpacing = ["compact", "comfortable"];
    expect(validSpacing).toContain(DEFAULTS.spacing);
  });

  test("has reasonable font size", () => {
    expect(DEFAULTS.fontSize).toBeGreaterThan(0);
    expect(DEFAULTS.fontSize).toBeLessThan(100);
  });

  test("has reasonable line height", () => {
    expect(DEFAULTS.lineHeight).toBeGreaterThan(0);
    expect(DEFAULTS.lineHeight).toBeLessThan(5);
  });

  test("has reasonable cursor opacity", () => {
    expect(DEFAULTS.cursorOpacity).toBeGreaterThanOrEqual(0);
    expect(DEFAULTS.cursorOpacity).toBeLessThanOrEqual(1);
  });
});
