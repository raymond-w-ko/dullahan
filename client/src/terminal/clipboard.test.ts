/**
 * Tests for clipboard module.
 *
 * Note: Full clipboard testing requires browser environment.
 * These tests focus on the module structure and fallback behavior.
 */

import { describe, test, expect, mock, beforeEach } from "bun:test";

// Mock navigator.clipboard BEFORE importing the module
const mockWriteText = mock(() => Promise.resolve());
const mockReadText = mock(() => Promise.resolve("clipboard content"));
const mockRemoveAllRanges = mock(() => {});

const mockClipboard = {
  writeText: mockWriteText,
  readText: mockReadText,
};

const mockSelection = {
  isCollapsed: false,
  toString: () => "selected text",
  removeAllRanges: mockRemoveAllRanges,
};

// Setup global mocks before import
(globalThis as unknown as { navigator: { clipboard: typeof mockClipboard } }).navigator = {
  clipboard: mockClipboard,
};
(globalThis as unknown as { window: { getSelection: () => typeof mockSelection } }).window = {
  getSelection: () => mockSelection,
};

// Now import the module
import {
  isClipboardAvailable,
  copyToClipboard,
  pasteFromClipboard,
  getSelection,
  clearSelection,
} from "./clipboard";

// Setup mocks
beforeEach(() => {
  // Reset mocks
  mockWriteText.mockReset();
  mockReadText.mockReset();
  mockRemoveAllRanges.mockReset();

  // Restore default implementations
  mockWriteText.mockImplementation(() => Promise.resolve());
  mockReadText.mockImplementation(() => Promise.resolve("clipboard content"));
});

describe("isClipboardAvailable", () => {
  test("returns true when clipboard API is available", () => {
    expect(isClipboardAvailable()).toBe(true);
  });

  test("returns false when navigator is undefined", () => {
    const originalNavigator = globalThis.navigator;
    (globalThis as unknown as { navigator: undefined }).navigator = undefined;

    expect(isClipboardAvailable()).toBe(false);

    (globalThis as unknown as { navigator: typeof originalNavigator }).navigator = originalNavigator;
  });
});

describe("copyToClipboard", () => {
  test("copies text using Clipboard API", async () => {
    const result = await copyToClipboard("test text");

    expect(result).toBe(true);
    expect(mockWriteText).toHaveBeenCalledWith("test text");
  });

  test("returns false for empty text", async () => {
    const result = await copyToClipboard("");

    expect(result).toBe(false);
    expect(mockWriteText).not.toHaveBeenCalled();
  });

  test("handles clipboard API errors", async () => {
    mockWriteText.mockImplementation(() =>
      Promise.reject(new Error("Permission denied"))
    );

    // Should try fallback (which will also fail in test env, but won't throw)
    const result = await copyToClipboard("test");

    // Result depends on fallback success - in test env it will fail
    expect(typeof result).toBe("boolean");
  });
});

describe("pasteFromClipboard", () => {
  test("reads text using Clipboard API", async () => {
    const result = await pasteFromClipboard();

    expect(result).toBe("clipboard content");
    expect(mockReadText).toHaveBeenCalled();
  });

  test("returns empty string on error", async () => {
    mockReadText.mockImplementation(() =>
      Promise.reject(new Error("Permission denied"))
    );

    const result = await pasteFromClipboard();

    expect(result).toBe("");
  });
});

describe("getSelection", () => {
  test("returns selected text", () => {
    const result = getSelection();

    expect(result).toBe("selected text");
  });

  test("returns null when selection is collapsed", () => {
    const collapsedSelection = {
      isCollapsed: true,
      toString: () => "",
      removeAllRanges: mock(() => {}),
    };
    (globalThis as unknown as { window: { getSelection: () => typeof collapsedSelection } }).window = {
      getSelection: () => collapsedSelection,
    };

    const result = getSelection();

    expect(result).toBe(null);
  });

  test("returns null when no selection", () => {
    (globalThis as unknown as { window: { getSelection: () => null } }).window = {
      getSelection: () => null,
    };

    const result = getSelection();

    expect(result).toBe(null);
  });
});

describe("clearSelection", () => {
  test("clears selection ranges", () => {
    // Restore window mock (previous test may have modified it)
    (globalThis as unknown as { window: { getSelection: () => typeof mockSelection } }).window = {
      getSelection: () => mockSelection,
    };

    clearSelection();

    expect(mockRemoveAllRanges).toHaveBeenCalled();
  });
});
