/**
 * Tests for keybind string parser.
 */

import { describe, test, expect } from "bun:test";
import type { Keybind } from "./keybinds";
import { parseKeybind, matchesKeybind, formatKeybind } from "./keybinds";

describe("parseKeybind", () => {
  test("single letter key", () => {
    const keybind = parseKeybind("c");
    expect(keybind).toEqual({
      key: "c",
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    });
  });

  test("ctrl+key", () => {
    const keybind = parseKeybind("ctrl+c");
    expect(keybind).toEqual({
      key: "c",
      ctrl: true,
      alt: false,
      shift: false,
      meta: false,
    });
  });

  test("ctrl+shift+key", () => {
    const keybind = parseKeybind("ctrl+shift+c");
    expect(keybind).toEqual({
      key: "c",
      ctrl: true,
      alt: false,
      shift: true,
      meta: false,
    });
  });

  test("alt+key", () => {
    const keybind = parseKeybind("alt+enter");
    expect(keybind).toEqual({
      key: "Enter",
      ctrl: false,
      alt: true,
      shift: false,
      meta: false,
    });
  });

  test("super maps to meta", () => {
    const keybind = parseKeybind("super+k");
    expect(keybind).toEqual({
      key: "k",
      ctrl: false,
      alt: false,
      shift: false,
      meta: true,
    });
  });

  test("cmd maps to meta", () => {
    const keybind = parseKeybind("cmd+k");
    expect(keybind.meta).toBe(true);
  });

  test("option maps to alt", () => {
    const keybind = parseKeybind("option+x");
    expect(keybind.alt).toBe(true);
  });

  test("control maps to ctrl", () => {
    const keybind = parseKeybind("control+a");
    expect(keybind.ctrl).toBe(true);
  });

  test("all modifiers", () => {
    const keybind = parseKeybind("ctrl+alt+shift+super+x");
    expect(keybind).toEqual({
      key: "x",
      ctrl: true,
      alt: true,
      shift: true,
      meta: true,
    });
  });

  test("case insensitive", () => {
    const keybind = parseKeybind("CTRL+SHIFT+C");
    expect(keybind).toEqual({
      key: "c",
      ctrl: true,
      alt: false,
      shift: true,
      meta: false,
    });
  });

  describe("special keys", () => {
    test("page_up", () => {
      const keybind = parseKeybind("shift+page_up");
      expect(keybind.key).toBe("PageUp");
      expect(keybind.shift).toBe(true);
    });

    test("pageup (no underscore)", () => {
      const keybind = parseKeybind("pageup");
      expect(keybind.key).toBe("PageUp");
    });

    test("page_down", () => {
      const keybind = parseKeybind("page_down");
      expect(keybind.key).toBe("PageDown");
    });

    test("arrow keys", () => {
      expect(parseKeybind("up").key).toBe("ArrowUp");
      expect(parseKeybind("down").key).toBe("ArrowDown");
      expect(parseKeybind("left").key).toBe("ArrowLeft");
      expect(parseKeybind("right").key).toBe("ArrowRight");
    });

    test("enter", () => {
      expect(parseKeybind("enter").key).toBe("Enter");
      expect(parseKeybind("return").key).toBe("Enter");
    });

    test("space", () => {
      expect(parseKeybind("space").key).toBe(" ");
    });

    test("tab", () => {
      expect(parseKeybind("tab").key).toBe("Tab");
    });

    test("escape", () => {
      expect(parseKeybind("escape").key).toBe("Escape");
      expect(parseKeybind("esc").key).toBe("Escape");
    });

    test("backspace", () => {
      expect(parseKeybind("backspace").key).toBe("Backspace");
    });

    test("delete", () => {
      expect(parseKeybind("delete").key).toBe("Delete");
      expect(parseKeybind("del").key).toBe("Delete");
    });

    test("home and end", () => {
      expect(parseKeybind("home").key).toBe("Home");
      expect(parseKeybind("end").key).toBe("End");
    });

    test("insert", () => {
      expect(parseKeybind("insert").key).toBe("Insert");
      expect(parseKeybind("ins").key).toBe("Insert");
    });

    test("function keys", () => {
      expect(parseKeybind("f1").key).toBe("F1");
      expect(parseKeybind("f12").key).toBe("F12");
      expect(parseKeybind("ctrl+f5").key).toBe("F5");
    });

    test("punctuation aliases", () => {
      expect(parseKeybind("plus").key).toBe("+");
      expect(parseKeybind("minus").key).toBe("-");
      expect(parseKeybind("equal").key).toBe("=");
      expect(parseKeybind("comma").key).toBe(",");
      expect(parseKeybind("period").key).toBe(".");
      expect(parseKeybind("slash").key).toBe("/");
      expect(parseKeybind("backslash").key).toBe("\\");
    });
  });

  test("throws on empty key", () => {
    expect(() => parseKeybind("ctrl+")).toThrow("no key found");
    expect(() => parseKeybind("")).toThrow("no key found");
    expect(() => parseKeybind("ctrl+shift+")).toThrow("no key found");
  });
});

describe("matchesKeybind", () => {
  function mockEvent(options: {
    key: string;
    ctrlKey?: boolean;
    altKey?: boolean;
    shiftKey?: boolean;
    metaKey?: boolean;
  }): KeyboardEvent {
    return {
      key: options.key,
      ctrlKey: options.ctrlKey ?? false,
      altKey: options.altKey ?? false,
      shiftKey: options.shiftKey ?? false,
      metaKey: options.metaKey ?? false,
    } as KeyboardEvent;
  }

  test("matches simple key", () => {
    const keybind = parseKeybind("c");
    expect(matchesKeybind(mockEvent({ key: "c" }), keybind)).toBe(true);
    expect(matchesKeybind(mockEvent({ key: "C" }), keybind)).toBe(true); // case insensitive
    expect(matchesKeybind(mockEvent({ key: "d" }), keybind)).toBe(false);
  });

  test("matches ctrl+key", () => {
    const keybind = parseKeybind("ctrl+c");
    expect(
      matchesKeybind(mockEvent({ key: "c", ctrlKey: true }), keybind)
    ).toBe(true);
    expect(matchesKeybind(mockEvent({ key: "c" }), keybind)).toBe(false);
    expect(
      matchesKeybind(mockEvent({ key: "c", ctrlKey: true, shiftKey: true }), keybind)
    ).toBe(false); // extra modifier
  });

  test("matches ctrl+shift+key", () => {
    const keybind = parseKeybind("ctrl+shift+c");
    expect(
      matchesKeybind(
        mockEvent({ key: "c", ctrlKey: true, shiftKey: true }),
        keybind
      )
    ).toBe(true);
    expect(
      matchesKeybind(mockEvent({ key: "c", ctrlKey: true }), keybind)
    ).toBe(false);
  });

  test("matches special keys", () => {
    const keybind = parseKeybind("shift+page_up");
    expect(
      matchesKeybind(mockEvent({ key: "PageUp", shiftKey: true }), keybind)
    ).toBe(true);
  });

  test("matches meta/super", () => {
    const keybind = parseKeybind("super+k");
    expect(
      matchesKeybind(mockEvent({ key: "k", metaKey: true }), keybind)
    ).toBe(true);
  });

  test("requires exact modifier match", () => {
    const keybind = parseKeybind("ctrl+c");
    // Extra modifiers should not match
    expect(
      matchesKeybind(
        mockEvent({ key: "c", ctrlKey: true, altKey: true }),
        keybind
      )
    ).toBe(false);
    expect(
      matchesKeybind(
        mockEvent({ key: "c", ctrlKey: true, metaKey: true }),
        keybind
      )
    ).toBe(false);
  });

  test("matches all modifiers", () => {
    const keybind = parseKeybind("ctrl+alt+shift+super+x");
    expect(
      matchesKeybind(
        mockEvent({
          key: "x",
          ctrlKey: true,
          altKey: true,
          shiftKey: true,
          metaKey: true,
        }),
        keybind
      )
    ).toBe(true);
  });

  test("matches function keys", () => {
    const keybind = parseKeybind("ctrl+f5");
    expect(
      matchesKeybind(mockEvent({ key: "F5", ctrlKey: true }), keybind)
    ).toBe(true);
  });

  test("matches space", () => {
    const keybind = parseKeybind("ctrl+space");
    expect(
      matchesKeybind(mockEvent({ key: " ", ctrlKey: true }), keybind)
    ).toBe(true);
  });
});

describe("formatKeybind", () => {
  test("formats simple key", () => {
    const keybind = parseKeybind("c");
    expect(formatKeybind(keybind)).toBe("c");
  });

  test("formats with modifiers", () => {
    const keybind = parseKeybind("ctrl+shift+c");
    expect(formatKeybind(keybind)).toBe("ctrl+shift+c");
  });

  test("formats with all modifiers in consistent order", () => {
    const keybind = parseKeybind("super+alt+shift+ctrl+x");
    expect(formatKeybind(keybind)).toBe("ctrl+alt+shift+super+x");
  });

  test("formats special keys", () => {
    expect(formatKeybind(parseKeybind("page_up"))).toBe("page_up");
    expect(formatKeybind(parseKeybind("up"))).toBe("up");
    expect(formatKeybind(parseKeybind("space"))).toBe("space");
  });

  test("round-trips correctly", () => {
    const originals = [
      "ctrl+c",
      "ctrl+shift+c",
      "super+k",
      "alt+enter",
      "shift+page_up",
      "f1",
      "ctrl+alt+delete",
    ];

    for (const original of originals) {
      const keybind = parseKeybind(original);
      const formatted = formatKeybind(keybind);
      const reparsed = parseKeybind(formatted);
      expect(reparsed).toEqual(keybind);
    }
  });
});
