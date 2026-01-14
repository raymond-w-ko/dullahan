/**
 * Zig-style String Literal Parser
 *
 * Parses escape sequences in strings, matching Ghostty's keybind syntax.
 * Used by text:, csi:, and esc: keybind actions.
 *
 * Supported escapes:
 * - \\ → backslash
 * - \n → newline (LF)
 * - \r → carriage return (CR)
 * - \t → tab
 * - \x?? → hex byte (2 digits)
 * - \u{...} → unicode codepoint
 */

/**
 * Parse a string containing Zig-style escape sequences.
 *
 * @param input - String with escape sequences (e.g., "hello\\nworld", "\\x1b[A")
 * @returns Parsed string with escapes resolved
 * @throws Error if escape sequence is invalid
 *
 * @example
 * parseStringLiteral("\\x1b[A") // "\x1b[A" (ESC [ A)
 * parseStringLiteral("hello\\nworld") // "hello\nworld"
 * parseStringLiteral("\\x15") // "\x15" (Ctrl+U)
 */
export function parseStringLiteral(input: string): string {
  const result: string[] = [];
  let i = 0;

  while (i < input.length) {
    if (input[i] === "\\") {
      if (i + 1 >= input.length) {
        throw new Error("Unterminated escape sequence at end of string");
      }

      const next = input[i + 1];

      switch (next) {
        case "\\":
          result.push("\\");
          i += 2;
          break;

        case "n":
          result.push("\n");
          i += 2;
          break;

        case "r":
          result.push("\r");
          i += 2;
          break;

        case "t":
          result.push("\t");
          i += 2;
          break;

        case "0":
          result.push("\0");
          i += 2;
          break;

        case "x":
          // Hex escape: \x??
          if (i + 3 >= input.length) {
            throw new Error(
              `Incomplete hex escape at position ${i}: expected \\x?? but got "${input.slice(i)}"`
            );
          }
          const hexStr = input.slice(i + 2, i + 4);
          const hexVal = parseInt(hexStr, 16);
          if (isNaN(hexVal)) {
            throw new Error(
              `Invalid hex escape at position ${i}: \\x${hexStr}`
            );
          }
          result.push(String.fromCharCode(hexVal));
          i += 4;
          break;

        case "u":
          // Unicode escape: \u{...}
          if (input[i + 2] !== "{") {
            throw new Error(
              `Invalid unicode escape at position ${i}: expected \\u{...}`
            );
          }
          const closeIdx = input.indexOf("}", i + 3);
          if (closeIdx === -1) {
            throw new Error(
              `Unterminated unicode escape at position ${i}: missing }`
            );
          }
          const codePointStr = input.slice(i + 3, closeIdx);
          const codePoint = parseInt(codePointStr, 16);
          if (isNaN(codePoint)) {
            throw new Error(
              `Invalid unicode codepoint at position ${i}: \\u{${codePointStr}}`
            );
          }
          if (codePoint > 0x10ffff) {
            throw new Error(
              `Unicode codepoint out of range at position ${i}: \\u{${codePointStr}}`
            );
          }
          result.push(String.fromCodePoint(codePoint));
          i = closeIdx + 1;
          break;

        default:
          throw new Error(
            `Unknown escape sequence at position ${i}: \\${next}`
          );
      }
    } else {
      result.push(input[i]);
      i++;
    }
  }

  return result.join("");
}
