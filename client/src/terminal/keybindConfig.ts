/**
 * Keybind Configuration System
 *
 * Provides default keybinds (Ghostty-compatible) and localStorage customization.
 * Parses keybind strings like "ctrl+shift+c=copy_to_clipboard" into
 * structured KeybindEntry objects for the KeyboardHandler.
 */

import type { KeybindEntry } from "./keyboard";
import type { TerminalAction } from "./actions";
import { parseKeybind } from "./keybinds";
import { parseStringLiteral } from "./stringLiteral";

const STORAGE_KEY = "dullahan.keybinds";

/**
 * Default keybinds matching Ghostty's defaults.
 * Format: "keybind_string=action_string"
 */
export const DEFAULT_KEYBIND_STRINGS: string[] = [
  // Clipboard (Linux/Windows style)
  "ctrl+shift+c=copy_to_clipboard",
  "ctrl+shift+v=paste_from_clipboard",

  // Clipboard (macOS style)
  "super+c=copy_to_clipboard",
  "super+v=paste_from_clipboard",

  // Scrolling
  "shift+page_up=scroll_page_up",
  "shift+page_down=scroll_page_down",
  "shift+home=scroll_to_top",
  "shift+end=scroll_to_bottom",
  "shift+up=scroll_line_up",
  "shift+down=scroll_line_down",

  // Windows
  "ctrl+shift+n=new_window",
  "ctrl+tab=next_window",
  "ctrl+shift+tab=prev_window",

  // Direct window switching (alt+1 through alt+9)
  "alt+1=switch_window:1",
  "alt+2=switch_window:2",
  "alt+3=switch_window:3",
  "alt+4=switch_window:4",
  "alt+5=switch_window:5",
  "alt+6=switch_window:6",
  "alt+7=switch_window:7",
  "alt+8=switch_window:8",
  "alt+9=switch_window:9",

  // Pane navigation
  "ctrl+shift+left=focus_pane:left",
  "ctrl+shift+right=focus_pane:right",
  "ctrl+shift+up=focus_pane:up",
  "ctrl+shift+down=focus_pane:down",

  // Settings
  "ctrl+comma=open_settings",
  "super+comma=open_settings",
];

/**
 * Parse an action string into a TerminalAction.
 * Handles parameterized actions like "scroll_page_up" or "switch_window:1"
 */
export function parseAction(actionStr: string): TerminalAction | null {
  // Handle parameterized actions (action:param)
  const colonIdx = actionStr.indexOf(":");
  const actionName = colonIdx >= 0 ? actionStr.slice(0, colonIdx) : actionStr;
  const param = colonIdx >= 0 ? actionStr.slice(colonIdx + 1) : null;

  switch (actionName) {
    // Clipboard
    case "copy_to_clipboard":
      return { type: "copy_to_clipboard" };
    case "paste_from_clipboard":
      return { type: "paste_from_clipboard" };

    // Scroll - expanded aliases
    case "scroll_page_up":
      return { type: "scroll", direction: "up", amount: "page" };
    case "scroll_page_down":
      return { type: "scroll", direction: "down", amount: "page" };
    case "scroll_half_page_up":
      return { type: "scroll", direction: "up", amount: "half_page" };
    case "scroll_half_page_down":
      return { type: "scroll", direction: "down", amount: "half_page" };
    case "scroll_line_up":
      return { type: "scroll", direction: "up", amount: "line" };
    case "scroll_line_down":
      return { type: "scroll", direction: "down", amount: "line" };
    case "scroll_to_top":
      return { type: "scroll", direction: "up", amount: "top" };
    case "scroll_to_bottom":
      return { type: "scroll", direction: "down", amount: "bottom" };

    // Windows
    case "new_window":
      return { type: "new_window" };
    case "close_window":
      return { type: "close_window" };
    case "next_window":
      return { type: "cycle_window", direction: "next" };
    case "prev_window":
      return { type: "cycle_window", direction: "prev" };
    case "switch_window":
      if (param) {
        const idx = parseInt(param, 10);
        if (!isNaN(idx) && idx >= 1 && idx <= 9) {
          return { type: "switch_window", windowIndex: idx };
        }
      }
      return null;

    // Panes
    case "focus_pane":
      if (param) {
        const dir = param as "up" | "down" | "left" | "right" | "next" | "prev";
        if (["up", "down", "left", "right", "next", "prev"].includes(dir)) {
          return { type: "focus_pane", direction: dir };
        }
      }
      return null;
    case "next_pane":
      return { type: "focus_pane", direction: "next" };
    case "prev_pane":
      return { type: "focus_pane", direction: "prev" };

    // Terminal control
    case "clear_screen":
      return { type: "clear_screen" };
    case "reset_terminal":
      return { type: "reset_terminal" };

    // UI
    case "open_settings":
      return { type: "open_settings" };
    case "toggle_fullscreen":
      return { type: "toggle_fullscreen" };

    // Unbind
    case "none":
    case "unbind":
      return { type: "none" };

    // Raw input actions (Ghostty-compatible)
    case "text":
      // text:xxx - send literal text with escape parsing
      if (param !== null) {
        try {
          return { type: "send_text", text: parseStringLiteral(param) };
        } catch (err) {
          console.warn(`Invalid text: action: ${err}`);
          return null;
        }
      }
      return null;

    case "csi":
      // csi:xxx - send CSI sequence (ESC [ + xxx)
      if (param !== null) {
        try {
          return { type: "send_text", text: "\x1b[" + parseStringLiteral(param) };
        } catch (err) {
          console.warn(`Invalid csi: action: ${err}`);
          return null;
        }
      }
      return null;

    case "esc":
      // esc:xxx - send ESC sequence (ESC + xxx)
      if (param !== null) {
        try {
          return { type: "send_text", text: "\x1b" + parseStringLiteral(param) };
        } catch (err) {
          console.warn(`Invalid esc: action: ${err}`);
          return null;
        }
      }
      return null;

    default:
      console.warn(`Unknown keybind action: ${actionStr}`);
      return null;
  }
}

/**
 * Parse a keybind config string like "ctrl+shift+c=copy_to_clipboard"
 * into a KeybindEntry.
 */
export function parseKeybindConfig(configStr: string): KeybindEntry | null {
  const eqIdx = configStr.indexOf("=");
  if (eqIdx < 0) {
    console.warn(`Invalid keybind config (no '='): ${configStr}`);
    return null;
  }

  const keybindStr = configStr.slice(0, eqIdx).trim();
  const actionStr = configStr.slice(eqIdx + 1).trim();

  if (!keybindStr || !actionStr) {
    console.warn(`Invalid keybind config (empty parts): ${configStr}`);
    return null;
  }

  try {
    const keybind = parseKeybind(keybindStr);
    const action = parseAction(actionStr);

    if (!action) {
      return null;
    }

    return { keybind, action };
  } catch (err) {
    console.warn(`Failed to parse keybind config: ${configStr}`, err);
    return null;
  }
}

/**
 * Parse multiple keybind config strings into KeybindEntry array.
 */
export function parseKeybindConfigs(configStrs: string[]): KeybindEntry[] {
  const entries: KeybindEntry[] = [];

  for (const str of configStrs) {
    const entry = parseKeybindConfig(str);
    if (entry) {
      entries.push(entry);
    }
  }

  return entries;
}

/**
 * Get the default keybinds as KeybindEntry array.
 */
export function getDefaultKeybinds(): KeybindEntry[] {
  return parseKeybindConfigs(DEFAULT_KEYBIND_STRINGS);
}

/**
 * Get custom keybinds from localStorage.
 * Returns null if no custom keybinds are set.
 */
export function getCustomKeybinds(): string[] | null {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (!stored) return null;

    const parsed = JSON.parse(stored);
    if (Array.isArray(parsed)) {
      return parsed.filter((s) => typeof s === "string");
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Save custom keybinds to localStorage.
 * Pass null to clear custom keybinds (revert to defaults).
 */
export function setCustomKeybinds(keybinds: string[] | null): void {
  try {
    if (keybinds === null) {
      localStorage.removeItem(STORAGE_KEY);
    } else {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(keybinds));
    }

    // Dispatch event so components can react
    window.dispatchEvent(
      new CustomEvent("keybinds-change", { detail: { keybinds } })
    );
  } catch {
    console.warn("Failed to save custom keybinds");
  }
}

/**
 * Get the active keybinds (custom if set, otherwise defaults).
 */
export function getActiveKeybinds(): KeybindEntry[] {
  const custom = getCustomKeybinds();
  if (custom) {
    return parseKeybindConfigs(custom);
  }
  return getDefaultKeybinds();
}

/**
 * Get the active keybind strings (for display/editing).
 */
export function getActiveKeybindStrings(): string[] {
  return getCustomKeybinds() ?? DEFAULT_KEYBIND_STRINGS;
}

/**
 * Hook for listening to keybind changes.
 */
export function onKeybindsChange(
  callback: (keybinds: KeybindEntry[]) => void
): () => void {
  const handler = () => {
    callback(getActiveKeybinds());
  };

  window.addEventListener("keybinds-change", handler);
  return () => window.removeEventListener("keybinds-change", handler);
}
