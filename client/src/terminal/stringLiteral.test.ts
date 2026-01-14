/**
 * Tests for Zig-style string literal parser.
 */

import { describe, test, expect } from "bun:test";
import { parseStringLiteral } from "./stringLiteral";

describe("parseStringLiteral", () => {
  describe("basic escapes", () => {
    test("parses backslash escape", () => {
      expect(parseStringLiteral("\\\\")).toBe("\\");
      expect(parseStringLiteral("a\\\\b")).toBe("a\\b");
    });

    test("parses newline escape", () => {
      expect(parseStringLiteral("\\n")).toBe("\n");
      expect(parseStringLiteral("hello\\nworld")).toBe("hello\nworld");
    });

    test("parses carriage return escape", () => {
      expect(parseStringLiteral("\\r")).toBe("\r");
      expect(parseStringLiteral("\\r\\n")).toBe("\r\n");
    });

    test("parses tab escape", () => {
      expect(parseStringLiteral("\\t")).toBe("\t");
      expect(parseStringLiteral("col1\\tcol2")).toBe("col1\tcol2");
    });

    test("parses null escape", () => {
      expect(parseStringLiteral("\\0")).toBe("\0");
    });
  });

  describe("hex escapes", () => {
    test("parses hex escape \\x00", () => {
      expect(parseStringLiteral("\\x00")).toBe("\x00");
    });

    test("parses hex escape \\x1b (ESC)", () => {
      expect(parseStringLiteral("\\x1b")).toBe("\x1b");
    });

    test("parses hex escape \\x15 (Ctrl+U)", () => {
      expect(parseStringLiteral("\\x15")).toBe("\x15");
    });

    test("parses hex escape \\x7f (DEL)", () => {
      expect(parseStringLiteral("\\x7f")).toBe("\x7f");
    });

    test("parses hex escape \\xff", () => {
      expect(parseStringLiteral("\\xff")).toBe("\xff");
    });

    test("parses uppercase hex", () => {
      expect(parseStringLiteral("\\x1B")).toBe("\x1b");
      expect(parseStringLiteral("\\xFF")).toBe("\xff");
    });

    test("parses hex in context", () => {
      expect(parseStringLiteral("\\x1b[A")).toBe("\x1b[A");
      expect(parseStringLiteral("\\x1b[2J")).toBe("\x1b[2J");
    });

    test("throws on incomplete hex escape", () => {
      expect(() => parseStringLiteral("\\x")).toThrow(/Incomplete hex escape/);
      expect(() => parseStringLiteral("\\x1")).toThrow(/Incomplete hex escape/);
    });

    test("throws on invalid hex digits", () => {
      expect(() => parseStringLiteral("\\xZZ")).toThrow(/Invalid hex escape/);
      expect(() => parseStringLiteral("\\xGH")).toThrow(/Invalid hex escape/);
    });
  });

  describe("unicode escapes", () => {
    test("parses basic unicode codepoint", () => {
      expect(parseStringLiteral("\\u{41}")).toBe("A");
      expect(parseStringLiteral("\\u{0041}")).toBe("A");
    });

    test("parses unicode emoji", () => {
      expect(parseStringLiteral("\\u{1F600}")).toBe("\u{1F600}");
    });

    test("parses multiple unicode escapes", () => {
      expect(parseStringLiteral("\\u{48}\\u{69}")).toBe("Hi");
    });

    test("throws on missing opening brace", () => {
      expect(() => parseStringLiteral("\\u41")).toThrow(
        /expected \\u\{...\}/
      );
    });

    test("throws on missing closing brace", () => {
      expect(() => parseStringLiteral("\\u{41")).toThrow(
        /Unterminated unicode escape/
      );
    });

    test("throws on invalid codepoint", () => {
      expect(() => parseStringLiteral("\\u{ZZZZ}")).toThrow(
        /Invalid unicode codepoint/
      );
    });

    test("throws on out of range codepoint", () => {
      expect(() => parseStringLiteral("\\u{FFFFFF}")).toThrow(
        /out of range/
      );
    });
  });

  describe("mixed content", () => {
    test("parses string with no escapes", () => {
      expect(parseStringLiteral("hello")).toBe("hello");
      expect(parseStringLiteral("")).toBe("");
      expect(parseStringLiteral("abc123")).toBe("abc123");
    });

    test("parses mixed escapes and literals", () => {
      expect(parseStringLiteral("hello\\nworld")).toBe("hello\nworld");
      expect(parseStringLiteral("\\x1b[Aup")).toBe("\x1b[Aup");
    });

    test("parses multiple consecutive escapes", () => {
      expect(parseStringLiteral("\\n\\n\\n")).toBe("\n\n\n");
      expect(parseStringLiteral("\\x1b\\x1b")).toBe("\x1b\x1b");
    });

    test("parses CSI sequence", () => {
      // CSI A (cursor up)
      expect(parseStringLiteral("\\x1b[A")).toBe("\x1b[A");
      // CSI 2J (clear screen)
      expect(parseStringLiteral("\\x1b[2J")).toBe("\x1b[2J");
      // CSI 1;5A (Ctrl+Up)
      expect(parseStringLiteral("\\x1b[1;5A")).toBe("\x1b[1;5A");
    });

    test("parses echo command with newline", () => {
      expect(parseStringLiteral("echo hello\\n")).toBe("echo hello\n");
    });
  });

  describe("edge cases", () => {
    test("handles empty string", () => {
      expect(parseStringLiteral("")).toBe("");
    });

    test("throws on trailing backslash", () => {
      expect(() => parseStringLiteral("\\")).toThrow(
        /Unterminated escape sequence/
      );
      expect(() => parseStringLiteral("hello\\")).toThrow(
        /Unterminated escape sequence/
      );
    });

    test("throws on unknown escape", () => {
      expect(() => parseStringLiteral("\\q")).toThrow(/Unknown escape sequence/);
      expect(() => parseStringLiteral("\\a")).toThrow(/Unknown escape sequence/);
    });

    test("preserves special characters without backslash", () => {
      expect(parseStringLiteral("[A")).toBe("[A");
      expect(parseStringLiteral("{test}")).toBe("{test}");
    });
  });
});
