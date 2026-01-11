/**
 * Keybind string parser for Ghostty-style keybind syntax.
 *
 * Parses strings like "ctrl+shift+c" into structured keybind objects
 * and provides matching against KeyboardEvents.
 */

export interface Keybind {
  key: string; // Normalized key value (e.g., 'c', 'Enter', 'PageUp', 'F1')
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean; // super/cmd
}

/**
 * Modifier name mappings (case-insensitive).
 */
const MODIFIER_MAP: Record<string, keyof Omit<Keybind, "key">> = {
  ctrl: "ctrl",
  control: "ctrl",
  alt: "alt",
  option: "alt",
  opt: "alt",
  shift: "shift",
  meta: "meta",
  super: "meta",
  cmd: "meta",
  command: "meta",
  win: "meta",
  windows: "meta",
};

/**
 * Special key name mappings to KeyboardEvent.key values (case-insensitive).
 */
const KEY_MAP: Record<string, string> = {
  // Navigation
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
  page_up: "PageUp",
  pageup: "PageUp",
  page_down: "PageDown",
  pagedown: "PageDown",
  home: "Home",
  end: "End",

  // Editing
  enter: "Enter",
  return: "Enter",
  space: " ",
  tab: "Tab",
  backspace: "Backspace",
  delete: "Delete",
  del: "Delete",
  insert: "Insert",
  ins: "Insert",

  // Escape
  escape: "Escape",
  esc: "Escape",

  // Function keys
  f1: "F1",
  f2: "F2",
  f3: "F3",
  f4: "F4",
  f5: "F5",
  f6: "F6",
  f7: "F7",
  f8: "F8",
  f9: "F9",
  f10: "F10",
  f11: "F11",
  f12: "F12",

  // Punctuation that may have alternate names
  plus: "+",
  minus: "-",
  equal: "=",
  equals: "=",
  comma: ",",
  period: ".",
  dot: ".",
  slash: "/",
  backslash: "\\",
  semicolon: ";",
  quote: "'",
  apostrophe: "'",
  backtick: "`",
  grave: "`",
  bracket_left: "[",
  bracket_right: "]",
  left_bracket: "[",
  right_bracket: "]",
};

/**
 * Parse a Ghostty-style keybind string into a structured Keybind object.
 *
 * @example
 * parseKeybind("ctrl+shift+c")
 * // => { key: "c", ctrl: true, alt: false, shift: true, meta: false }
 *
 * parseKeybind("super+k")
 * // => { key: "k", ctrl: false, alt: false, shift: false, meta: true }
 *
 * parseKeybind("page_up")
 * // => { key: "PageUp", ctrl: false, alt: false, shift: false, meta: false }
 */
export function parseKeybind(str: string): Keybind {
  const keybind: Keybind = {
    key: "",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  };

  const parts = str.toLowerCase().split("+");

  for (const rawPart of parts) {
    const part = rawPart.trim();
    if (!part) continue;

    // Check if this is a modifier
    const modifier = MODIFIER_MAP[part];
    if (modifier) {
      keybind[modifier] = true;
      continue;
    }

    // Last non-modifier part is the key
    // Map special key names or use as-is for single characters
    keybind.key = KEY_MAP[part] ?? normalizeKey(part);
  }

  if (!keybind.key) {
    throw new Error(`Invalid keybind string: no key found in "${str}"`);
  }

  return keybind;
}

/**
 * Normalize a key name for comparison.
 * Single characters stay lowercase, special keys get proper casing.
 */
function normalizeKey(key: string): string {
  // Single character keys should match as-is (lowercase for comparison)
  if (key.length === 1) {
    return key.toLowerCase();
  }

  // Multi-character keys might be special keys we didn't map
  // Try to match common patterns
  return key;
}

/**
 * Check if a KeyboardEvent matches a Keybind.
 *
 * @example
 * const keybind = parseKeybind("ctrl+c");
 * matchesKeybind(event, keybind); // true if Ctrl+C was pressed
 */
export function matchesKeybind(
  event: KeyboardEvent,
  keybind: Keybind
): boolean {
  // Check modifiers match exactly
  if (event.ctrlKey !== keybind.ctrl) return false;
  if (event.altKey !== keybind.alt) return false;
  if (event.shiftKey !== keybind.shift) return false;
  if (event.metaKey !== keybind.meta) return false;

  // Check key matches (case-insensitive for letters)
  const eventKey = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  const bindKey =
    keybind.key.length === 1 ? keybind.key.toLowerCase() : keybind.key;

  return eventKey === bindKey;
}

/**
 * Convert a Keybind back to a string representation.
 * Useful for displaying keybinds in UI or debugging.
 */
export function formatKeybind(keybind: Keybind): string {
  const parts: string[] = [];

  if (keybind.ctrl) parts.push("ctrl");
  if (keybind.alt) parts.push("alt");
  if (keybind.shift) parts.push("shift");
  if (keybind.meta) parts.push("super");

  // Format the key for display
  parts.push(formatKeyForDisplay(keybind.key));

  return parts.join("+");
}

/**
 * Format a key value for display (reverse of KEY_MAP).
 */
function formatKeyForDisplay(key: string): string {
  // Check reverse mappings for common special keys
  switch (key) {
    case "ArrowUp":
      return "up";
    case "ArrowDown":
      return "down";
    case "ArrowLeft":
      return "left";
    case "ArrowRight":
      return "right";
    case "PageUp":
      return "page_up";
    case "PageDown":
      return "page_down";
    case " ":
      return "space";
    default:
      return key.toLowerCase();
  }
}
