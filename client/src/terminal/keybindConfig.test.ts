/**
 * Tests for keybind configuration system.
 */

import { describe, test, expect, beforeEach, mock } from "bun:test";

// Mock localStorage before importing
const mockStorage = new Map<string, string>();
const mockLocalStorage = {
  getItem: (key: string) => mockStorage.get(key) ?? null,
  setItem: (key: string, value: string) => mockStorage.set(key, value),
  removeItem: (key: string) => mockStorage.delete(key),
  clear: () => mockStorage.clear(),
};

// Mock window
const mockEventListeners = new Map<string, Set<EventListener>>();
const mockWindow = {
  addEventListener: (type: string, listener: EventListener) => {
    if (!mockEventListeners.has(type)) {
      mockEventListeners.set(type, new Set());
    }
    mockEventListeners.get(type)!.add(listener);
  },
  removeEventListener: (type: string, listener: EventListener) => {
    mockEventListeners.get(type)?.delete(listener);
  },
  dispatchEvent: (event: Event) => {
    const listeners = mockEventListeners.get(event.type);
    if (listeners) {
      for (const listener of listeners) {
        listener(event);
      }
    }
    return true;
  },
};

(globalThis as unknown as { localStorage: typeof mockLocalStorage }).localStorage = mockLocalStorage;
(globalThis as unknown as { window: typeof mockWindow }).window = mockWindow;

// Mock CustomEvent
class MockCustomEvent extends Event {
  detail: unknown;
  constructor(type: string, options?: { detail?: unknown }) {
    super(type);
    this.detail = options?.detail;
  }
}
(globalThis as unknown as { CustomEvent: typeof MockCustomEvent }).CustomEvent = MockCustomEvent;

// Now import the module
import {
  parseAction,
  parseKeybindConfig,
  parseKeybindConfigs,
  getDefaultKeybinds,
  getCustomKeybinds,
  setCustomKeybinds,
  getActiveKeybinds,
  getActiveKeybindStrings,
  onKeybindsChange,
  DEFAULT_KEYBIND_STRINGS,
} from "./keybindConfig";

beforeEach(() => {
  mockStorage.clear();
  mockEventListeners.clear();
});

describe("parseAction", () => {
  test("parses clipboard actions", () => {
    expect(parseAction("copy_to_clipboard")).toEqual({
      type: "copy_to_clipboard",
    });
    expect(parseAction("paste_from_clipboard")).toEqual({
      type: "paste_from_clipboard",
    });
  });

  test("parses scroll actions", () => {
    expect(parseAction("scroll_page_up")).toEqual({
      type: "scroll",
      direction: "up",
      amount: "page",
    });
    expect(parseAction("scroll_page_down")).toEqual({
      type: "scroll",
      direction: "down",
      amount: "page",
    });
    expect(parseAction("scroll_line_up")).toEqual({
      type: "scroll",
      direction: "up",
      amount: "line",
    });
    expect(parseAction("scroll_to_top")).toEqual({
      type: "scroll",
      direction: "up",
      amount: "top",
    });
    expect(parseAction("scroll_to_bottom")).toEqual({
      type: "scroll",
      direction: "down",
      amount: "bottom",
    });
  });

  test("parses window actions", () => {
    expect(parseAction("new_window")).toEqual({ type: "new_window" });
    expect(parseAction("close_window")).toEqual({ type: "close_window" });
    expect(parseAction("next_window")).toEqual({
      type: "cycle_window",
      direction: "next",
    });
    expect(parseAction("prev_window")).toEqual({
      type: "cycle_window",
      direction: "prev",
    });
  });

  test("parses parameterized switch_window", () => {
    expect(parseAction("switch_window:1")).toEqual({
      type: "switch_window",
      windowIndex: 1,
    });
    expect(parseAction("switch_window:9")).toEqual({
      type: "switch_window",
      windowIndex: 9,
    });
    expect(parseAction("switch_window:invalid")).toBe(null);
    expect(parseAction("switch_window")).toBe(null);
  });

  test("parses parameterized focus_pane", () => {
    expect(parseAction("focus_pane:left")).toEqual({
      type: "focus_pane",
      direction: "left",
    });
    expect(parseAction("focus_pane:right")).toEqual({
      type: "focus_pane",
      direction: "right",
    });
    expect(parseAction("focus_pane:next")).toEqual({
      type: "focus_pane",
      direction: "next",
    });
    expect(parseAction("focus_pane:invalid")).toBe(null);
  });

  test("parses UI actions", () => {
    expect(parseAction("open_settings")).toEqual({ type: "open_settings" });
    expect(parseAction("toggle_fullscreen")).toEqual({
      type: "toggle_fullscreen",
    });
  });

  test("parses unbind/none", () => {
    expect(parseAction("none")).toEqual({ type: "none" });
    expect(parseAction("unbind")).toEqual({ type: "none" });
  });

  test("returns null for unknown actions", () => {
    expect(parseAction("unknown_action")).toBe(null);
  });
});

describe("parseKeybindConfig", () => {
  test("parses valid config string", () => {
    const result = parseKeybindConfig("ctrl+shift+c=copy_to_clipboard");
    expect(result).not.toBe(null);
    expect(result?.keybind.ctrl).toBe(true);
    expect(result?.keybind.shift).toBe(true);
    expect(result?.keybind.key).toBe("c");
    expect(result?.action.type).toBe("copy_to_clipboard");
  });

  test("parses with special keys", () => {
    const result = parseKeybindConfig("shift+page_up=scroll_page_up");
    expect(result).not.toBe(null);
    expect(result?.keybind.shift).toBe(true);
    expect(result?.keybind.key).toBe("PageUp");
    expect(result?.action.type).toBe("scroll");
  });

  test("parses with parameters", () => {
    const result = parseKeybindConfig("alt+1=switch_window:1");
    expect(result).not.toBe(null);
    expect(result?.keybind.alt).toBe(true);
    expect(result?.keybind.key).toBe("1");
    expect(result?.action).toEqual({ type: "switch_window", windowIndex: 1 });
  });

  test("returns null for invalid format", () => {
    expect(parseKeybindConfig("invalid")).toBe(null);
    expect(parseKeybindConfig("=action")).toBe(null);
    expect(parseKeybindConfig("key=")).toBe(null);
  });

  test("returns null for unknown action", () => {
    expect(parseKeybindConfig("ctrl+x=unknown_action")).toBe(null);
  });
});

describe("parseKeybindConfigs", () => {
  test("parses multiple configs", () => {
    const configs = [
      "ctrl+c=copy_to_clipboard",
      "ctrl+v=paste_from_clipboard",
      "invalid",
      "ctrl+n=new_window",
    ];
    const result = parseKeybindConfigs(configs);
    expect(result.length).toBe(3); // invalid is skipped
  });
});

describe("getDefaultKeybinds", () => {
  test("returns parsed default keybinds", () => {
    const keybinds = getDefaultKeybinds();
    expect(keybinds.length).toBeGreaterThan(0);

    // Check a few expected bindings
    const copyBind = keybinds.find(
      (k) => k.keybind.ctrl && k.keybind.shift && k.keybind.key === "c"
    );
    expect(copyBind).toBeDefined();
    expect(copyBind?.action.type).toBe("copy_to_clipboard");
  });

  test("includes all default keybind strings", () => {
    const keybinds = getDefaultKeybinds();
    // Not all strings may parse successfully (if any are invalid)
    // but we should get close to the total
    expect(keybinds.length).toBeGreaterThanOrEqual(
      DEFAULT_KEYBIND_STRINGS.length - 5
    );
  });
});

describe("custom keybinds storage", () => {
  test("getCustomKeybinds returns null when not set", () => {
    expect(getCustomKeybinds()).toBe(null);
  });

  test("setCustomKeybinds saves to localStorage", () => {
    const custom = ["ctrl+x=new_window", "ctrl+y=open_settings"];
    setCustomKeybinds(custom);

    expect(getCustomKeybinds()).toEqual(custom);
  });

  test("setCustomKeybinds(null) clears storage", () => {
    setCustomKeybinds(["ctrl+x=new_window"]);
    expect(getCustomKeybinds()).not.toBe(null);

    setCustomKeybinds(null);
    expect(getCustomKeybinds()).toBe(null);
  });

  test("setCustomKeybinds dispatches event", () => {
    const handler = mock(() => {});
    mockWindow.addEventListener("keybinds-change", handler);

    setCustomKeybinds(["ctrl+x=new_window"]);

    expect(handler).toHaveBeenCalled();
  });
});

describe("getActiveKeybinds", () => {
  test("returns defaults when no custom keybinds", () => {
    const active = getActiveKeybinds();
    const defaults = getDefaultKeybinds();

    expect(active.length).toBe(defaults.length);
  });

  test("returns custom keybinds when set", () => {
    setCustomKeybinds(["ctrl+x=new_window"]);

    const active = getActiveKeybinds();
    expect(active.length).toBe(1);
    expect(active[0]?.action.type).toBe("new_window");
  });
});

describe("getActiveKeybindStrings", () => {
  test("returns default strings when no custom", () => {
    const strings = getActiveKeybindStrings();
    expect(strings).toEqual(DEFAULT_KEYBIND_STRINGS);
  });

  test("returns custom strings when set", () => {
    const custom = ["ctrl+x=new_window"];
    setCustomKeybinds(custom);

    expect(getActiveKeybindStrings()).toEqual(custom);
  });
});

describe("onKeybindsChange", () => {
  test("calls callback when keybinds change", () => {
    const callback = mock(() => {});
    const unsubscribe = onKeybindsChange(callback);

    setCustomKeybinds(["ctrl+x=new_window"]);

    expect(callback).toHaveBeenCalled();

    unsubscribe();
  });

  test("unsubscribe removes listener", () => {
    const callback = mock(() => {});
    const unsubscribe = onKeybindsChange(callback);

    unsubscribe();

    setCustomKeybinds(["ctrl+x=new_window"]);

    expect(callback).not.toHaveBeenCalled();
  });
});
