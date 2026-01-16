/**
 * Tests for terminal action system.
 */

import { describe, test, expect } from "bun:test";
import { canPerformAction, type ActionContext, type TerminalAction } from "./actions";

/**
 * Create a mock ActionContext for testing.
 */
function createMockContext(overrides: Partial<ActionContext> = {}): ActionContext {
  return {
    paneId: 1,
    sendText: () => {},
    sendScroll: () => {},
    getSelection: () => null,
    readClipboard: async () => "",
    writeClipboard: async () => {},
    switchWindow: () => {},
    getWindowIds: () => [0],
    getActiveWindowId: () => 0,
    createWindow: () => {},
    closeWindow: () => {},
    openSettings: () => {},
    setFocusedPane: () => {},
    getPaneIds: () => [1],
    getFocusedPaneId: () => 1,
    ...overrides,
  };
}

describe("canPerformAction", () => {
  describe("copy_to_clipboard", () => {
    test("returns true when there is a selection", () => {
      const ctx = createMockContext({
        getSelection: () => "selected text",
      });
      const action: TerminalAction = { type: "copy_to_clipboard" };
      expect(canPerformAction(action, ctx)).toBe(true);
    });

    test("returns false when selection is null", () => {
      const ctx = createMockContext({
        getSelection: () => null,
      });
      const action: TerminalAction = { type: "copy_to_clipboard" };
      expect(canPerformAction(action, ctx)).toBe(false);
    });

    test("returns false when selection is empty string", () => {
      const ctx = createMockContext({
        getSelection: () => "",
      });
      const action: TerminalAction = { type: "copy_to_clipboard" };
      expect(canPerformAction(action, ctx)).toBe(false);
    });
  });

  describe("switch_window", () => {
    test("returns true when target window exists", () => {
      const ctx = createMockContext({
        getWindowIds: () => [0, 1, 2],
      });
      const action: TerminalAction = { type: "switch_window", windowIndex: 2 };
      expect(canPerformAction(action, ctx)).toBe(true);
    });

    test("returns false when target window does not exist", () => {
      const ctx = createMockContext({
        getWindowIds: () => [0, 1],
      });
      const action: TerminalAction = { type: "switch_window", windowIndex: 5 };
      expect(canPerformAction(action, ctx)).toBe(false);
    });

    test("returns false for index 0 (1-based)", () => {
      const ctx = createMockContext({
        getWindowIds: () => [0, 1],
      });
      // windowIndex is 1-based, so 0 is invalid
      const action: TerminalAction = { type: "switch_window", windowIndex: 0 };
      expect(canPerformAction(action, ctx)).toBe(false);
    });
  });

  describe("cycle_window", () => {
    test("returns true when multiple windows exist", () => {
      const ctx = createMockContext({
        getWindowIds: () => [0, 1],
      });
      const action: TerminalAction = { type: "cycle_window", direction: "next" };
      expect(canPerformAction(action, ctx)).toBe(true);
    });

    test("returns false when only one window exists", () => {
      const ctx = createMockContext({
        getWindowIds: () => [0],
      });
      const action: TerminalAction = { type: "cycle_window", direction: "next" };
      expect(canPerformAction(action, ctx)).toBe(false);
    });
  });

  describe("focus_pane", () => {
    test("returns true when multiple panes exist", () => {
      const ctx = createMockContext({
        getPaneIds: () => [1, 2, 3],
      });
      const action: TerminalAction = { type: "focus_pane", direction: "next" };
      expect(canPerformAction(action, ctx)).toBe(true);
    });

    test("returns false when only one pane exists", () => {
      const ctx = createMockContext({
        getPaneIds: () => [1],
      });
      const action: TerminalAction = { type: "focus_pane", direction: "next" };
      expect(canPerformAction(action, ctx)).toBe(false);
    });
  });

  describe("always performable actions", () => {
    const alwaysPerformableActions: TerminalAction[] = [
      { type: "paste_from_clipboard" },
      { type: "scroll", direction: "up", amount: "line" },
      { type: "send_text", text: "test" },
      { type: "clear_screen" },
      { type: "reset_terminal" },
      { type: "new_window" },
      { type: "close_window" },
      { type: "toggle_fullscreen" },
      { type: "open_settings" },
      { type: "none" },
    ];

    for (const action of alwaysPerformableActions) {
      test(`${action.type} is always performable`, () => {
        const ctx = createMockContext();
        expect(canPerformAction(action, ctx)).toBe(true);
      });
    }
  });
});
