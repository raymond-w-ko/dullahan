/**
 * Tests for keyboard handler with keybind interception.
 */

import { describe, test, expect, beforeEach, mock, afterEach } from "bun:test";

// Mock window for tests
const mockWindow = {
  getSelection: () => ({ toString: () => "" }),
};
(globalThis as unknown as { window: typeof mockWindow }).window = mockWindow;
import { KeyboardHandler } from "./keyboard";
import type { KeybindEntry, KeyMessage } from "./keyboard";
import { parseKeybind } from "./keybinds";
import type { ActionContext, TerminalAction } from "./actions";

// Mock KeyboardEvent
function createKeyboardEvent(
  type: "keydown" | "keyup",
  options: {
    key: string;
    code: string;
    ctrlKey?: boolean;
    altKey?: boolean;
    shiftKey?: boolean;
    metaKey?: boolean;
    repeat?: boolean;
  }
): KeyboardEvent {
  return {
    type,
    key: options.key,
    code: options.code,
    keyCode: 0,
    ctrlKey: options.ctrlKey ?? false,
    altKey: options.altKey ?? false,
    shiftKey: options.shiftKey ?? false,
    metaKey: options.metaKey ?? false,
    repeat: options.repeat ?? false,
    preventDefault: mock(() => {}),
    stopPropagation: mock(() => {}),
  } as unknown as KeyboardEvent;
}

// Mock ActionContext
function createMockActionContext(): ActionContext & {
  calls: { action: string; args?: unknown }[];
} {
  const calls: { action: string; args?: unknown }[] = [];

  return {
    calls,
    paneId: 1,
    sendText: (text: string) => {
      calls.push({ action: "sendText", args: text });
    },
    sendScroll: (paneId: number, lines: number) => {
      calls.push({ action: "sendScroll", args: { paneId, lines } });
    },
    getSelection: () => null,
    readClipboard: async () => "",
    writeClipboard: async () => {},
    switchWindow: (id: number) => {
      calls.push({ action: "switchWindow", args: id });
    },
    getWindowIds: () => [0],
    getActiveWindowId: () => 0,
    createWindow: () => {
      calls.push({ action: "createWindow" });
    },
    closeWindow: (id: number) => {
      calls.push({ action: "closeWindow", args: id });
    },
    openSettings: () => {
      calls.push({ action: "openSettings" });
    },
    setFocusedPane: () => {},
    getPaneIds: () => [1],
    getFocusedPaneId: () => 1,
    toggleFullscreen: (paneId: number) => {
      calls.push({ action: "toggleFullscreen", args: paneId });
    },
    selectAll: (paneId: number) => {
      calls.push({ action: "selectAll", args: paneId });
    },
    clearSelectionInPane: (paneId: number) => {
      calls.push({ action: "clearSelectionInPane", args: paneId });
    },
  };
}

// Mock HTMLElement for attach
function createMockElement(): HTMLElement & {
  listeners: Map<string, ((e: Event) => void)[]>;
  triggerKeyDown: (e: KeyboardEvent) => void;
  triggerKeyUp: (e: KeyboardEvent) => void;
} {
  const listeners = new Map<string, ((e: Event) => void)[]>();

  const element = {
    listeners,
    hasAttribute: () => false,
    setAttribute: () => {},
    addEventListener: (type: string, handler: (e: Event) => void) => {
      if (!listeners.has(type)) {
        listeners.set(type, []);
      }
      listeners.get(type)!.push(handler);
    },
    removeEventListener: (type: string, handler: (e: Event) => void) => {
      const handlers = listeners.get(type);
      if (handlers) {
        const idx = handlers.indexOf(handler);
        if (idx >= 0) handlers.splice(idx, 1);
      }
    },
    focus: () => {},
    triggerKeyDown: (e: KeyboardEvent) => {
      const handlers = listeners.get("keydown") ?? [];
      for (const handler of handlers) {
        handler(e);
      }
    },
    triggerKeyUp: (e: KeyboardEvent) => {
      const handlers = listeners.get("keyup") ?? [];
      for (const handler of handlers) {
        handler(e);
      }
    },
  };

  return element as unknown as HTMLElement & typeof element;
}

describe("KeyboardHandler", () => {
  let handler: KeyboardHandler;
  let element: ReturnType<typeof createMockElement>;
  let messages: KeyMessage[];
  let ctx: ReturnType<typeof createMockActionContext>;

  beforeEach(() => {
    handler = new KeyboardHandler();
    element = createMockElement();
    messages = [];
    ctx = createMockActionContext();

    handler.attach(element, (msg) => messages.push(msg));
    handler.setActionContext(ctx);
  });

  describe("basic key handling", () => {
    test("sends keydown to callback", () => {
      const event = createKeyboardEvent("keydown", { key: "a", code: "KeyA" });
      element.triggerKeyDown(event);

      expect(messages.length).toBe(1);
      expect(messages[0]?.key).toBe("a");
      expect(messages[0]?.state).toBe("down");
    });

    test("sends keyup to callback", () => {
      const event = createKeyboardEvent("keyup", { key: "a", code: "KeyA" });
      element.triggerKeyUp(event);

      expect(messages.length).toBe(1);
      expect(messages[0]?.key).toBe("a");
      expect(messages[0]?.state).toBe("up");
    });

    test("passes modifier keys through", () => {
      const ctrlDown = createKeyboardEvent("keydown", {
        key: "Control",
        code: "ControlLeft",
        ctrlKey: true,
      });
      element.triggerKeyDown(ctrlDown);

      expect(messages.length).toBe(1);
      expect(messages[0]?.code).toBe("ControlLeft");
      expect(messages[0]?.state).toBe("down");
    });
  });

  describe("keybind interception", () => {
    test("intercepts matching keybind and executes action", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+shift+c"),
          action: { type: "copy_to_clipboard" },
        },
      ];
      handler.setKeybinds(keybinds);

      const event = createKeyboardEvent("keydown", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
        shiftKey: true,
      });
      element.triggerKeyDown(event);

      // Should NOT send to server
      expect(messages.length).toBe(0);
      // Action context doesn't track copy directly, but we can verify no sendText
    });

    test("does not intercept non-matching keys", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+shift+c"),
          action: { type: "copy_to_clipboard" },
        },
      ];
      handler.setKeybinds(keybinds);

      const event = createKeyboardEvent("keydown", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
        // Missing shift
      });
      element.triggerKeyDown(event);

      // Should send to server
      expect(messages.length).toBe(1);
      expect(messages[0]?.key).toBe("c");
    });

    test("suppresses keyup for consumed keys", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "copy_to_clipboard" },
        },
      ];
      handler.setKeybinds(keybinds);

      // Keydown - should be consumed
      const keydown = createKeyboardEvent("keydown", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyDown(keydown);
      expect(messages.length).toBe(0);

      // Keyup - should also be suppressed
      const keyup = createKeyboardEvent("keyup", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyUp(keyup);
      expect(messages.length).toBe(0);
    });

    test("does not suppress keyup for non-consumed keys", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "copy_to_clipboard" },
        },
      ];
      handler.setKeybinds(keybinds);

      // Regular key - not consumed
      const keydown = createKeyboardEvent("keydown", {
        key: "a",
        code: "KeyA",
      });
      element.triggerKeyDown(keydown);
      expect(messages.length).toBe(1);

      // Keyup should also pass through
      const keyup = createKeyboardEvent("keyup", { key: "a", code: "KeyA" });
      element.triggerKeyUp(keyup);
      expect(messages.length).toBe(2);
      expect(messages[1]?.state).toBe("up");
    });

    test("modifier keys pass through even during keybind", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "copy_to_clipboard" },
        },
      ];
      handler.setKeybinds(keybinds);

      // Ctrl down - should pass through
      const ctrlDown = createKeyboardEvent("keydown", {
        key: "Control",
        code: "ControlLeft",
        ctrlKey: true,
      });
      element.triggerKeyDown(ctrlDown);
      expect(messages.length).toBe(1);
      expect(messages[0]?.code).toBe("ControlLeft");

      // C down - should be consumed (keybind match)
      const cDown = createKeyboardEvent("keydown", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyDown(cDown);
      expect(messages.length).toBe(1); // Still 1, C was consumed

      // C up - should be suppressed
      const cUp = createKeyboardEvent("keyup", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyUp(cUp);
      expect(messages.length).toBe(1); // Still 1

      // Ctrl up - should pass through
      const ctrlUp = createKeyboardEvent("keyup", {
        key: "Control",
        code: "ControlLeft",
      });
      element.triggerKeyUp(ctrlUp);
      expect(messages.length).toBe(2);
      expect(messages[1]?.code).toBe("ControlLeft");
      expect(messages[1]?.state).toBe("up");
    });

    test("executes action with correct context", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+n"),
          action: { type: "new_window" },
        },
      ];
      handler.setKeybinds(keybinds);

      const event = createKeyboardEvent("keydown", {
        key: "n",
        code: "KeyN",
        ctrlKey: true,
      });
      element.triggerKeyDown(event);

      expect(ctx.calls.length).toBe(1);
      expect(ctx.calls[0]?.action).toBe("createWindow");
    });

    test("ignores none action type", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+x"),
          action: { type: "none" },
        },
      ];
      handler.setKeybinds(keybinds);

      const event = createKeyboardEvent("keydown", {
        key: "x",
        code: "KeyX",
        ctrlKey: true,
      });
      element.triggerKeyDown(event);

      // none action should not intercept - key passes through
      expect(messages.length).toBe(1);
    });
  });

  describe("consumed key state management", () => {
    test("clearConsumedKeys resets state", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "copy_to_clipboard" },
        },
      ];
      handler.setKeybinds(keybinds);

      // Consume a key
      const keydown = createKeyboardEvent("keydown", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyDown(keydown);

      // Clear consumed keys
      handler.clearConsumedKeys();

      // Keyup should now pass through since state was cleared
      const keyup = createKeyboardEvent("keyup", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyUp(keyup);
      expect(messages.length).toBe(1); // Now it passes through
    });

    test("detach clears consumed keys", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "copy_to_clipboard" },
        },
      ];
      handler.setKeybinds(keybinds);

      // Consume a key
      const keydown = createKeyboardEvent("keydown", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyDown(keydown);

      // Detach and reattach
      handler.detach();
      const newMessages: KeyMessage[] = [];
      handler.attach(element, (msg) => newMessages.push(msg));

      // Keyup for previously consumed key should now pass through
      const keyup = createKeyboardEvent("keyup", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyUp(keyup);
      expect(newMessages.length).toBe(1);
    });
  });

  describe("multiple keybinds", () => {
    test("matches first keybind in order", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "copy_to_clipboard" },
        },
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "clear_screen" }, // Duplicate, should never match
        },
      ];
      handler.setKeybinds(keybinds);

      const event = createKeyboardEvent("keydown", {
        key: "c",
        code: "KeyC",
        ctrlKey: true,
      });
      element.triggerKeyDown(event);

      // copy_to_clipboard doesn't call sendText
      expect(ctx.calls.length).toBe(0);
    });

    test("different keybinds work independently", () => {
      const keybinds: KeybindEntry[] = [
        {
          keybind: parseKeybind("ctrl+c"),
          action: { type: "copy_to_clipboard" },
        },
        {
          keybind: parseKeybind("ctrl+v"),
          action: { type: "paste_from_clipboard" },
        },
        {
          keybind: parseKeybind("ctrl+n"),
          action: { type: "new_window" },
        },
      ];
      handler.setKeybinds(keybinds);

      // Trigger ctrl+n
      const event = createKeyboardEvent("keydown", {
        key: "n",
        code: "KeyN",
        ctrlKey: true,
      });
      element.triggerKeyDown(event);

      expect(messages.length).toBe(0); // Consumed
      expect(ctx.calls.length).toBe(1);
      expect(ctx.calls[0]?.action).toBe("createWindow");
    });
  });
});
