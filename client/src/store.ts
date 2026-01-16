// Global state store for terminal windows and panes
// Provides reactive state management without heavy dependencies

import { debug } from "./debug";
import { TerminalConnection } from "./terminal/connection";
import { AUDIO } from "./constants";
import type { TerminalSnapshot, LayoutUpdate, WindowLayout, LayoutTemplate } from "./terminal/connection";
import * as config from "./config";

export interface WindowState {
  id: number;
  paneIds: number[];
  focusedPaneId: number;
  layout?: WindowLayout;
}

export interface PaneState {
  id: number;
  title: string;
  snapshot: TerminalSnapshot | null;
  syncStats: { deltas: number; resyncs: number; gen: number };
  isReadOnly: boolean;
  dimensions: { cols: number; rows: number };
}

export interface Store {
  // Connection state
  connection: TerminalConnection | null;
  connected: boolean;
  error: string | null;

  // Master/slave state
  isMaster: boolean;
  masterId: string | null;

  // Window/pane layout
  activeWindowId: number;
  windows: Map<number, WindowState>;
  panes: Map<number, PaneState>;
  focusedPaneId: number;

  // Layout templates (from server)
  layoutTemplates: LayoutTemplate[];
  layoutPickerOpen: boolean;

  // UI state
  bellActive: boolean;
  settingsOpen: boolean;
  dimensionVersion: number; // Incremented when font settings change

  // Config (mirrored from config module for reactivity)
  theme: string;
  cursorStyle: "block" | "bar" | "underline" | "block_hollow";
  cursorColor: string;
  cursorText: string;
  cursorBlink: "" | "true" | "false";
}

type Listener = () => void;

// Create initial pane state
function createPaneState(
  id: number,
  title: string,
  isReadOnly: boolean
): PaneState {
  return {
    id,
    title,
    snapshot: null,
    syncStats: { deltas: 0, resyncs: 0, gen: 0 },
    isReadOnly,
    dimensions: { cols: 80, rows: 24 },
  };
}

// Global store instance
const store: Store = {
  connection: null,
  connected: false,
  error: null,

  isMaster: false,
  masterId: null,

  activeWindowId: 0,
  windows: new Map(),  // Populated by server layout message
  panes: new Map(),    // Populated by server layout message

  focusedPaneId: 0,

  layoutTemplates: [],
  layoutPickerOpen: false,

  bellActive: false,
  settingsOpen: false,
  dimensionVersion: 0, // Incremented when font settings change to trigger recalc

  theme: config.get("theme") as string,
  cursorStyle: config.get("cursorStyle") as Store["cursorStyle"],
  cursorColor: config.get("cursorColor") as string,
  cursorText: config.get("cursorText") as string,
  cursorBlink: config.get("cursorBlink") as Store["cursorBlink"],
};

// Listeners for reactive updates
const listeners = new Set<Listener>();

function notify() {
  listeners.forEach((fn) => fn());
}

// Public API
export function getStore(): Readonly<Store> {
  return store;
}

export function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function getPane(paneId: number): PaneState | undefined {
  return store.panes.get(paneId);
}

export function getWindow(windowId: number): WindowState | undefined {
  return store.windows.get(windowId);
}

export function getConnection(): TerminalConnection | null {
  return store.connection;
}

// Mutations
export function setConnected(connected: boolean) {
  store.connected = connected;
  if (connected) store.error = null;
  notify();
}

export function setError(error: string | null) {
  store.error = error;
  notify();
}

export function setPaneSnapshot(paneId: number, snapshot: TerminalSnapshot) {
  // Create pane if it doesn't exist (snapshots may arrive before layout)
  let pane = store.panes.get(paneId);
  if (!pane) {
    pane = {
      id: paneId,
      title: `Pane ${paneId}`,
      snapshot: null,
      syncStats: { deltas: 0, resyncs: 0, gen: 0 },
      isReadOnly: false,
      dimensions: { cols: 80, rows: 24 },
    };
    store.panes.set(paneId, pane);
  }

  pane.snapshot = snapshot;
  const conn = store.connection;
  if (conn) {
    pane.syncStats = {
      deltas: conn.getDeltaCount(paneId),
      resyncs: conn.getResyncCount(paneId),
      gen: snapshot.gen,
    };
  }
  notify();
}

export function updatePaneSyncStats(paneId: number, gen: number) {
  const pane = store.panes.get(paneId);
  const conn = store.connection;
  if (pane && conn) {
    pane.syncStats = {
      deltas: conn.getDeltaCount(paneId),
      resyncs: conn.getResyncCount(paneId),
      gen,
    };
    notify();
  }
}

export function setPaneTitle(paneId: number, title: string) {
  const pane = store.panes.get(paneId);
  if (pane) {
    pane.title = title;
    notify();
  }
}

export function setPaneDimensions(
  paneId: number,
  cols: number,
  rows: number
) {
  const pane = store.panes.get(paneId);
  if (pane) {
    pane.dimensions = { cols, rows };
    notify();
  }
}

export function setBellActive(active: boolean) {
  store.bellActive = active;
  notify();
}

export function setSettingsOpen(open: boolean) {
  store.settingsOpen = open;
  notify();
}

export function setFocusedPane(paneId: number) {
  store.focusedPaneId = paneId;
  notify();
}

export function setMasterState(masterId: string | null, isMaster: boolean) {
  store.masterId = masterId;
  store.isMaster = isMaster;
  notify();
}

export function requestMaster() {
  store.connection?.requestMaster();
}

export function createWindow() {
  store.connection?.createWindow();
}

export function setLayoutPickerOpen(open: boolean) {
  store.layoutPickerOpen = open;
  notify();
}

export function getLayoutTemplates(): LayoutTemplate[] {
  return store.layoutTemplates;
}

export function createWindowWithTemplate(templateId: string) {
  store.connection?.createWindow(templateId);
  setLayoutPickerOpen(false);
}

export function closeWindow(windowId: number) {
  store.connection?.closeWindow(windowId);
}

export function setLayout(layout: LayoutUpdate) {
  store.activeWindowId = layout.activeWindowId;

  // Update templates if provided
  if (layout.templates) {
    store.layoutTemplates = layout.templates;
  }

  // Update windows map from layout
  store.windows.clear();
  for (const win of layout.windows) {
    store.windows.set(win.id, {
      id: win.id,
      paneIds: win.panes,
      focusedPaneId: win.activePaneId,
      layout: win.layout,
    });
  }

  // Create pane states for any new panes we haven't seen
  for (const win of layout.windows) {
    for (const paneId of win.panes) {
      if (!store.panes.has(paneId)) {
        store.panes.set(paneId, {
          id: paneId,
          title: `Pane ${paneId}`,
          snapshot: null,
          syncStats: { deltas: 0, resyncs: 0, gen: 0 },
          isReadOnly: false,
          dimensions: { cols: 80, rows: 24 },
        });
      }
    }
  }

  notify();
}

export function switchWindow(windowId: number) {
  if (store.windows.has(windowId)) {
    store.activeWindowId = windowId;
    notify();
  }
}

export function getActiveWindow(): WindowState | undefined {
  return store.windows.get(store.activeWindowId);
}

// Trigger dimension recalculation (for font setting changes)
export function triggerDimensionRecalc() {
  store.dimensionVersion++;
  notify();
}

// Config sync
export function syncConfig() {
  store.theme = config.get("theme") as string;
  store.cursorStyle = config.get("cursorStyle") as Store["cursorStyle"];
  store.cursorColor = config.get("cursorColor") as string;
  store.cursorText = config.get("cursorText") as string;
  store.cursorBlink = config.get("cursorBlink") as Store["cursorBlink"];
  notify();
}

// Initialize connection and wire up handlers
export function initConnection() {
  if (store.connection) return;

  const conn = new TerminalConnection();
  store.connection = conn;

  conn.on("connect", () => {
    setConnected(true);
    // Trigger dimension recalculation shortly after connection
    // This ensures panes resize after layout settles
    setTimeout(() => triggerDimensionRecalc(), 100);
  });
  conn.on("disconnect", () => setConnected(false));
  conn.on("error", (err) => setError(err));

  conn.on("snapshot", (snap) => {
    setPaneSnapshot(snap.paneId, snap);
  });

  conn.on("delta", (delta) => {
    updatePaneSyncStats(delta.paneId, delta.gen);
  });

  conn.on("title", (paneId, title) => {
    // Update the specific pane's title
    setPaneTitle(paneId, title);
    // Update document title only if this is the focused pane
    if (paneId === store.focusedPaneId) {
      document.title = `${title} - Dullahan`;
    }
  });

  conn.on("bell", () => {
    const features = config.getBellFeatures();
    if (features.attention || features.title) {
      setBellActive(true);
    }
    if (features.audio) {
      playBellAudio();
    }
  });

  conn.on("masterChanged", (masterId, isMaster) => {
    setMasterState(masterId, isMaster);
  });

  conn.on("layout", (layout) => {
    setLayout(layout);
  });

  conn.connect();

  // Listen for config changes
  config.onChange((key, value) => {
    if (
      key === "theme" ||
      key === "cursorStyle" ||
      key === "cursorColor" ||
      key === "cursorText" ||
      key === "cursorBlink"
    ) {
      syncConfig();
    }
    // Font-related settings need dimension recalculation
    if (
      key === "fontSize" ||
      key === "fontFamily" ||
      key === "lineHeight" ||
      key === "fontStyle" ||
      key === "fontFeature"
    ) {
      // Short delay to let CSS update before measuring
      setTimeout(() => triggerDimensionRecalc(), 50);
    }
  });
}

export function disconnectConnection() {
  store.connection?.disconnect();
  store.connection = null;
  store.connected = false;
  notify();
}

// Bell audio (moved from App.tsx)
let audioContext: AudioContext | null = null;

function playBellAudio() {
  try {
    if (!audioContext) {
      audioContext = new AudioContext();
    }
    const ctx = audioContext;

    const oscillator = ctx.createOscillator();
    const gainNode = ctx.createGain();

    oscillator.type = "sine";
    oscillator.frequency.setValueAtTime(AUDIO.BELL_FREQUENCY, ctx.currentTime);

    gainNode.gain.setValueAtTime(0, ctx.currentTime);
    gainNode.gain.linearRampToValueAtTime(AUDIO.PEAK_GAIN, ctx.currentTime + AUDIO.ATTACK_TIME);
    gainNode.gain.exponentialRampToValueAtTime(AUDIO.MIN_GAIN, ctx.currentTime + AUDIO.DECAY_TIME);

    oscillator.connect(gainNode);
    gainNode.connect(ctx.destination);

    oscillator.start(ctx.currentTime);
    oscillator.stop(ctx.currentTime + AUDIO.DECAY_TIME);
  } catch (e) {
    debug.warn("Failed to play bell audio:", e);
  }
}
