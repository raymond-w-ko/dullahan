/**
 * Tests for global state store.
 */

import { describe, test, expect, beforeEach, afterEach, mock } from "bun:test";

// Mock the config module before importing store
const mockConfigValues: Record<string, any> = {
  theme: "selenized-light",
  cursorStyle: "block",
  cursorColor: "",
  cursorText: "",
  cursorBlink: "",
};

mock.module("./config", () => ({
  get: (key: string) => mockConfigValues[key] ?? "",
  getBellFeatures: () => ({ audio: true, attention: true, title: true }),
  onChange: () => () => {},
}));

// Now import store (after mocking)
import {
  getStore,
  subscribe,
  getPane,
  getWindow,
  setConnected,
  setError,
  setPaneSnapshot,
  setPaneTitle,
  setPaneDimensions,
  setBellActive,
  setSettingsOpen,
  setFocusedPane,
  setMasterState,
  setLayout,
  switchWindow,
  getActiveWindow,
  triggerDimensionRecalc,
  syncConfig,
  setLayoutPickerOpen,
  getLayoutTemplates,
  type WindowState,
  type PaneState,
} from "./store";
import type { TerminalSnapshot } from "./terminal/connection";

/** Create a valid mock snapshot for testing */
function createMockSnapshot(overrides: Partial<TerminalSnapshot> & { paneId: number }): TerminalSnapshot {
  return {
    paneId: overrides.paneId,
    gen: overrides.gen ?? 1,
    cols: overrides.cols ?? 80,
    rows: overrides.rows ?? 24,
    cursor: overrides.cursor ?? {
      x: 0,
      y: 0,
      visible: true,
      style: "block",
      blink: false,
    },
    altScreen: overrides.altScreen ?? false,
    scrollback: overrides.scrollback ?? { totalRows: 24, viewportTop: 0 },
    cells: overrides.cells ?? [],
    styles: overrides.styles ?? new Map(),
    rowIds: overrides.rowIds ?? [],
  };
}

describe("store initial state", () => {
  test("starts disconnected", () => {
    const store = getStore();
    expect(store.connected).toBe(false);
  });

  test("starts with no error", () => {
    const store = getStore();
    expect(store.error).toBeNull();
  });

  test("starts as non-master", () => {
    const store = getStore();
    expect(store.isMaster).toBe(false);
    expect(store.masterId).toBeNull();
  });

  test("starts with empty windows and panes", () => {
    const store = getStore();
    expect(store.windows.size).toBe(0);
    expect(store.panes.size).toBe(0);
  });

  test("starts with settings closed", () => {
    const store = getStore();
    expect(store.settingsOpen).toBe(false);
  });

  test("starts with bell inactive", () => {
    const store = getStore();
    expect(store.bellActive).toBe(false);
  });
});

describe("subscribe", () => {
  test("calls listener on state change", () => {
    let callCount = 0;
    const unsubscribe = subscribe(() => {
      callCount++;
    });

    setConnected(true);
    expect(callCount).toBe(1);

    setConnected(false);
    expect(callCount).toBe(2);

    unsubscribe();
  });

  test("unsubscribe stops notifications", () => {
    let callCount = 0;
    const unsubscribe = subscribe(() => {
      callCount++;
    });

    setConnected(true);
    expect(callCount).toBe(1);

    unsubscribe();

    setConnected(false);
    expect(callCount).toBe(1); // No additional calls
  });

  test("multiple listeners all get notified", () => {
    let count1 = 0;
    let count2 = 0;

    const unsub1 = subscribe(() => count1++);
    const unsub2 = subscribe(() => count2++);

    setConnected(true);
    expect(count1).toBe(1);
    expect(count2).toBe(1);

    unsub1();
    unsub2();
  });
});

describe("setConnected", () => {
  test("updates connected state", () => {
    setConnected(true);
    expect(getStore().connected).toBe(true);

    setConnected(false);
    expect(getStore().connected).toBe(false);
  });

  test("clears error when connected", () => {
    setError("Some error");
    expect(getStore().error).toBe("Some error");

    setConnected(true);
    expect(getStore().error).toBeNull();
  });

  test("preserves error when disconnected", () => {
    setError("Some error");
    setConnected(false);
    expect(getStore().error).toBe("Some error");
  });
});

describe("setError", () => {
  test("sets error message", () => {
    setError("Connection failed");
    expect(getStore().error).toBe("Connection failed");
  });

  test("clears error with null", () => {
    setError("Some error");
    setError(null);
    expect(getStore().error).toBeNull();
  });
});

describe("setPaneSnapshot", () => {
  test("creates pane if not exists", () => {
    const snapshot = createMockSnapshot({ paneId: 42 });

    setPaneSnapshot(42, snapshot);

    const pane = getPane(42);
    expect(pane).toBeDefined();
    expect(pane!.id).toBe(42);
    expect(pane!.snapshot).toBe(snapshot);
  });

  test("updates existing pane snapshot", () => {
    const snapshot1 = createMockSnapshot({ paneId: 1, gen: 1 });
    const snapshot2 = createMockSnapshot({
      paneId: 1,
      gen: 2,
      cursor: { x: 0, y: 5, visible: true, style: "block", blink: false },
    });

    setPaneSnapshot(1, snapshot1);
    setPaneSnapshot(1, snapshot2);

    const pane = getPane(1);
    expect(pane!.snapshot).toBe(snapshot2);
    expect(pane!.snapshot!.cursor.y).toBe(5);
  });

  test("sets default title for new pane", () => {
    const snapshot = createMockSnapshot({ paneId: 99 });

    setPaneSnapshot(99, snapshot);

    const pane = getPane(99);
    expect(pane!.title).toBe("Pane 99");
  });
});

describe("setPaneTitle", () => {
  test("updates pane title", () => {
    // First create the pane
    const snapshot = createMockSnapshot({ paneId: 1 });
    setPaneSnapshot(1, snapshot);

    setPaneTitle(1, "bash - ~/projects");

    const pane = getPane(1);
    expect(pane!.title).toBe("bash - ~/projects");
  });

  test("does nothing for non-existent pane", () => {
    // Should not throw
    setPaneTitle(999, "Some title");
    expect(getPane(999)).toBeUndefined();
  });
});

describe("setPaneDimensions", () => {
  test("updates pane dimensions", () => {
    const snapshot = createMockSnapshot({ paneId: 1 });
    setPaneSnapshot(1, snapshot);

    setPaneDimensions(1, 120, 40);

    const pane = getPane(1);
    expect(pane!.dimensions.cols).toBe(120);
    expect(pane!.dimensions.rows).toBe(40);
  });
});

describe("setBellActive", () => {
  test("sets bell active state", () => {
    setBellActive(true);
    expect(getStore().bellActive).toBe(true);

    setBellActive(false);
    expect(getStore().bellActive).toBe(false);
  });
});

describe("setSettingsOpen", () => {
  test("sets settings open state", () => {
    setSettingsOpen(true);
    expect(getStore().settingsOpen).toBe(true);

    setSettingsOpen(false);
    expect(getStore().settingsOpen).toBe(false);
  });
});

describe("setFocusedPane", () => {
  test("sets focused pane id", () => {
    setFocusedPane(5);
    expect(getStore().focusedPaneId).toBe(5);

    setFocusedPane(10);
    expect(getStore().focusedPaneId).toBe(10);
  });
});

describe("setMasterState", () => {
  test("sets master state", () => {
    setMasterState("client-123", true);

    const store = getStore();
    expect(store.masterId).toBe("client-123");
    expect(store.isMaster).toBe(true);
  });

  test("clears master state", () => {
    setMasterState("client-123", true);
    setMasterState(null, false);

    const store = getStore();
    expect(store.masterId).toBeNull();
    expect(store.isMaster).toBe(false);
  });
});

describe("setLayout", () => {
  test("sets active window id", () => {
    setLayout({
      activeWindowId: 2,
      windows: [],
    });

    expect(getStore().activeWindowId).toBe(2);
  });

  test("populates windows map", () => {
    setLayout({
      activeWindowId: 0,
      windows: [
        { id: 0, panes: [1, 2], activePaneId: 1 },
        { id: 1, panes: [3, 4, 5], activePaneId: 3 },
      ],
    });

    const store = getStore();
    expect(store.windows.size).toBe(2);

    const win0 = getWindow(0);
    expect(win0!.paneIds).toEqual([1, 2]);
    expect(win0!.focusedPaneId).toBe(1);

    const win1 = getWindow(1);
    expect(win1!.paneIds).toEqual([3, 4, 5]);
  });

  test("creates pane states for new panes", () => {
    setLayout({
      activeWindowId: 0,
      windows: [{ id: 0, panes: [10, 11, 12], activePaneId: 10 }],
    });

    expect(getPane(10)).toBeDefined();
    expect(getPane(11)).toBeDefined();
    expect(getPane(12)).toBeDefined();
  });

  test("preserves existing pane state", () => {
    // Create pane with snapshot
    const snapshot = createMockSnapshot({
      paneId: 1,
      gen: 5,
      cursor: { x: 20, y: 10, visible: true, style: "block", blink: false },
    });
    setPaneSnapshot(1, snapshot);

    // Update layout including this pane
    setLayout({
      activeWindowId: 0,
      windows: [{ id: 0, panes: [1, 2], activePaneId: 1 }],
    });

    // Pane 1 should still have its snapshot
    const pane = getPane(1);
    expect(pane!.snapshot).toBe(snapshot);
  });

  test("clears old windows on layout update", () => {
    setLayout({
      activeWindowId: 0,
      windows: [
        { id: 0, panes: [1], activePaneId: 1 },
        { id: 1, panes: [2], activePaneId: 2 },
      ],
    });

    expect(getStore().windows.size).toBe(2);

    // New layout with only one window
    setLayout({
      activeWindowId: 0,
      windows: [{ id: 0, panes: [1], activePaneId: 1 }],
    });

    expect(getStore().windows.size).toBe(1);
    expect(getWindow(1)).toBeUndefined();
  });

  test("updates layout templates when provided", () => {
    const templates = [
      { id: "single", name: "Single Pane", nodes: [] },
      { id: "2-col", name: "Two Columns", nodes: [] },
    ];

    setLayout({
      activeWindowId: 0,
      windows: [],
      templates,
    });

    expect(getLayoutTemplates()).toEqual(templates);
  });
});

describe("switchWindow", () => {
  beforeEach(() => {
    setLayout({
      activeWindowId: 0,
      windows: [
        { id: 0, panes: [1], activePaneId: 1 },
        { id: 1, panes: [2], activePaneId: 2 },
        { id: 2, panes: [3], activePaneId: 3 },
      ],
    });
  });

  test("switches to existing window", () => {
    switchWindow(1);
    expect(getStore().activeWindowId).toBe(1);

    switchWindow(2);
    expect(getStore().activeWindowId).toBe(2);
  });

  test("ignores non-existent window", () => {
    switchWindow(1);
    expect(getStore().activeWindowId).toBe(1);

    switchWindow(99);
    expect(getStore().activeWindowId).toBe(1); // Unchanged
  });
});

describe("getActiveWindow", () => {
  test("returns active window", () => {
    setLayout({
      activeWindowId: 1,
      windows: [
        { id: 0, panes: [1], activePaneId: 1 },
        { id: 1, panes: [2, 3], activePaneId: 2 },
      ],
    });

    const activeWindow = getActiveWindow();
    expect(activeWindow).toBeDefined();
    expect(activeWindow!.id).toBe(1);
    expect(activeWindow!.paneIds).toEqual([2, 3]);
  });

  test("returns undefined when no windows", () => {
    setLayout({
      activeWindowId: 0,
      windows: [],
    });

    expect(getActiveWindow()).toBeUndefined();
  });
});

describe("triggerDimensionRecalc", () => {
  test("increments dimension version", () => {
    const initialVersion = getStore().dimensionVersion;

    triggerDimensionRecalc();
    expect(getStore().dimensionVersion).toBe(initialVersion + 1);

    triggerDimensionRecalc();
    expect(getStore().dimensionVersion).toBe(initialVersion + 2);
  });

  test("notifies subscribers", () => {
    let notified = false;
    const unsub = subscribe(() => {
      notified = true;
    });

    triggerDimensionRecalc();
    expect(notified).toBe(true);

    unsub();
  });
});

describe("setLayoutPickerOpen", () => {
  test("sets layout picker open state", () => {
    setLayoutPickerOpen(true);
    expect(getStore().layoutPickerOpen).toBe(true);

    setLayoutPickerOpen(false);
    expect(getStore().layoutPickerOpen).toBe(false);
  });
});

describe("syncConfig", () => {
  test("syncs config values to store", () => {
    mockConfigValues.theme = "nord";
    mockConfigValues.cursorStyle = "bar";

    syncConfig();

    const store = getStore();
    expect(store.theme).toBe("nord");
    expect(store.cursorStyle).toBe("bar");
  });

  test("notifies subscribers", () => {
    let notified = false;
    const unsub = subscribe(() => {
      notified = true;
    });

    syncConfig();
    expect(notified).toBe(true);

    unsub();
  });
});
