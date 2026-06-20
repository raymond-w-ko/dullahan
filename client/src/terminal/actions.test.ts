/**
 * Tests for terminal action system.
 */

import { describe, test, expect } from "bun:test";
import {
  canPerformAction,
  executeAction,
  type ActionContext,
  type TerminalAction,
} from "./actions";
import {
  container,
  pane,
  type LayoutNode,
  type WindowLayout,
} from "../../../protocol/schema/layout";

/**
 * Create a mock ActionContext for testing.
 */
function createMockContext(overrides: Partial<ActionContext> = {}): ActionContext {
  return {
    paneId: 1,
    getViewportRows: () => 24,
    sendText: () => {},
    sendScroll: () => {},
    getSelection: () => null,
    readClipboard: async () => "",
    writeClipboard: async () => {},
    sendCopy: () => {},
    switchWindow: () => {},
    getWindowIds: () => [0],
    getActiveWindowId: () => 0,
    createWindow: () => {},
    closeWindow: () => {},
    openSettings: () => {},
    setFocusedPane: () => {},
    getPaneIds: () => [1],
    getFocusedPaneId: () => 1,
    getActiveWindowLayout: () => null,
    toggleFullscreen: () => {},
    selectAll: () => {},
    clearSelectionInPane: () => {},
    ...overrides,
  };
}

function testLayout(nodes: LayoutNode[]): WindowLayout {
  return { templateId: "test", nodes };
}

describe("canPerformAction", () => {
  describe("copy_to_clipboard", () => {
    test("returns false when no selection (allows Ctrl+C to pass through as SIGINT)", () => {
      const ctx = createMockContext({
        getSelection: () => null,
      });
      const action: TerminalAction = { type: "copy_to_clipboard" };
      expect(canPerformAction(action, ctx)).toBe(false);
    });

    test("returns true when there is a selection", () => {
      const ctx = createMockContext({
        getSelection: () => "selected text",
      });
      const action: TerminalAction = { type: "copy_to_clipboard" };
      expect(canPerformAction(action, ctx)).toBe(true);
    });

    test("returns false for empty selection", () => {
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
      { type: "select_all" },
      { type: "clear_selection" },
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

describe("executeAction", () => {
  test("focus_pane left/right uses 2-column layout and does not wrap at edges", async () => {
    const focused: number[] = [];
    const layout = testLayout([pane(50, 100, 1), pane(50, 100, 2)]);

    await executeAction(
      { type: "focus_pane", direction: "right" },
      createMockContext({
        getPaneIds: () => [1, 2],
        getFocusedPaneId: () => 1,
        getActiveWindowLayout: () => layout,
        setFocusedPane: (paneId) => focused.push(paneId),
      })
    );
    await executeAction(
      { type: "focus_pane", direction: "left" },
      createMockContext({
        getPaneIds: () => [1, 2],
        getFocusedPaneId: () => 1,
        getActiveWindowLayout: () => layout,
        setFocusedPane: (paneId) => focused.push(paneId),
      })
    );

    expect(focused).toEqual([2]);
  });

  test("focus_pane up/down uses 2-row layout and does not wrap at edges", async () => {
    const focused: number[] = [];
    const layout = testLayout([container(100, 100, [pane(100, 50, 1), pane(100, 50, 2)])]);

    await executeAction(
      { type: "focus_pane", direction: "down" },
      createMockContext({
        getPaneIds: () => [1, 2],
        getFocusedPaneId: () => 1,
        getActiveWindowLayout: () => layout,
        setFocusedPane: (paneId) => focused.push(paneId),
      })
    );
    await executeAction(
      { type: "focus_pane", direction: "up" },
      createMockContext({
        getPaneIds: () => [1, 2],
        getFocusedPaneId: () => 1,
        getActiveWindowLayout: () => layout,
        setFocusedPane: (paneId) => focused.push(paneId),
      })
    );

    expect(focused).toEqual([2]);
  });

  test("focus_pane navigates all directions in 2x2 layout", async () => {
    const layout = testLayout([
      container(50, 100, [pane(100, 50, 1), pane(100, 50, 2)]),
      container(50, 100, [pane(100, 50, 3), pane(100, 50, 4)]),
    ]);

    const focus = async (from: number, direction: "up" | "down" | "left" | "right") => {
      const focused: number[] = [];
      await executeAction(
        { type: "focus_pane", direction },
        createMockContext({
          getPaneIds: () => [1, 2, 3, 4],
          getFocusedPaneId: () => from,
          getActiveWindowLayout: () => layout,
          setFocusedPane: (paneId) => focused.push(paneId),
        })
      );
      return focused[0];
    };

    expect(await focus(1, "right")).toBe(3);
    expect(await focus(1, "down")).toBe(2);
    expect(await focus(4, "left")).toBe(2);
    expect(await focus(4, "up")).toBe(3);
  });

  test("focus_pane handles main pane with stacked side panes", async () => {
    const layout = testLayout([
      pane(50, 100, 1),
      container(50, 100, [pane(100, 50, 2), pane(100, 50, 3)]),
    ]);
    const focused: number[] = [];
    const context = (from: number) =>
      createMockContext({
        getPaneIds: () => [1, 2, 3],
        getFocusedPaneId: () => from,
        getActiveWindowLayout: () => layout,
        setFocusedPane: (paneId) => focused.push(paneId),
      });

    await executeAction({ type: "focus_pane", direction: "right" }, context(1));
    await executeAction({ type: "focus_pane", direction: "down" }, context(2));
    await executeAction({ type: "focus_pane", direction: "up" }, context(3));

    expect(focused).toEqual([2, 3, 2]);
  });

  test("focus_pane next/prev keeps pane-order cycling", async () => {
    const focused: number[] = [];
    const ctx = (from: number) =>
      createMockContext({
        getPaneIds: () => [1, 2, 3],
        getFocusedPaneId: () => from,
        setFocusedPane: (paneId) => focused.push(paneId),
      });

    await executeAction({ type: "focus_pane", direction: "next" }, ctx(1));
    await executeAction({ type: "focus_pane", direction: "prev" }, ctx(1));

    expect(focused).toEqual([2, 3]);
  });

  test("scroll_page_* uses live pane height", async () => {
    const calls: Array<{ paneId: number; lines: number }> = [];
    const ctx = createMockContext({
      getViewportRows: () => 37,
      sendScroll: (paneId, lines) => calls.push({ paneId, lines }),
    });

    await executeAction({ type: "scroll", direction: "up", amount: "page" }, ctx);
    await executeAction({ type: "scroll", direction: "down", amount: "page" }, ctx);

    expect(calls).toEqual([
      { paneId: 1, lines: -37 },
      { paneId: 1, lines: 37 },
    ]);
  });

  test("scroll_half_page_* uses half the pane height", async () => {
    const calls: Array<{ paneId: number; lines: number }> = [];
    const ctx = createMockContext({
      getViewportRows: () => 9,
      sendScroll: (paneId, lines) => calls.push({ paneId, lines }),
    });

    await executeAction({ type: "scroll", direction: "up", amount: "half_page" }, ctx);
    await executeAction({ type: "scroll", direction: "down", amount: "half_page" }, ctx);

    expect(calls).toEqual([
      { paneId: 1, lines: -4 },
      { paneId: 1, lines: 4 },
    ]);
  });
});
