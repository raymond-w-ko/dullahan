// Global state store for terminal windows and panes
// Provides reactive state management without heavy dependencies

import { TerminalConnection } from "./terminal/connection";
import type { TerminalSnapshot } from "./terminal/connection";
import * as config from "./config";

// Pane IDs (must match server session.zig)
export const DEBUG_PANE_ID = 0;
export const SHELL_PANE_1_ID = 1;
export const SHELL_PANE_2_ID = 2;

export interface WindowState {
  id: number;
  paneIds: number[];
  focusedPaneId: number;
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

  // Window/pane layout
  windows: Map<number, WindowState>;
  panes: Map<number, PaneState>;
  focusedPaneId: number;

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

  windows: new Map([
    [
      0,
      {
        id: 0,
        paneIds: [DEBUG_PANE_ID, SHELL_PANE_1_ID, SHELL_PANE_2_ID],
        focusedPaneId: SHELL_PANE_1_ID,
      },
    ],
  ]),

  panes: new Map([
    [DEBUG_PANE_ID, createPaneState(DEBUG_PANE_ID, "Debug Console", false)],
    [SHELL_PANE_1_ID, createPaneState(SHELL_PANE_1_ID, "Shell 1", false)],
    [SHELL_PANE_2_ID, createPaneState(SHELL_PANE_2_ID, "Shell 2", false)],
  ]),

  focusedPaneId: SHELL_PANE_1_ID,

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
  const pane = store.panes.get(paneId);
  if (pane) {
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

  conn.onConnect = () => setConnected(true);
  conn.onDisconnect = () => setConnected(false);
  conn.onError = (err) => setError(err);

  conn.onSnapshot = (snap) => {
    setPaneSnapshot(snap.paneId, snap);
  };

  conn.onDelta = (delta) => {
    updatePaneSyncStats(delta.paneId, delta.gen);
  };

  conn.onTitle = (paneId, title) => {
    // Update the specific pane's title
    setPaneTitle(paneId, title);
    // Update document title only if this is the focused pane
    if (paneId === store.focusedPaneId) {
      document.title = `${title} - Dullahan`;
    }
  };

  conn.onBell = () => {
    const features = config.getBellFeatures();
    if (features.attention || features.title) {
      setBellActive(true);
    }
    if (features.audio) {
      playBellAudio();
    }
  };

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
    oscillator.frequency.setValueAtTime(880, ctx.currentTime);

    gainNode.gain.setValueAtTime(0, ctx.currentTime);
    gainNode.gain.linearRampToValueAtTime(0.3, ctx.currentTime + 0.01);
    gainNode.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.15);

    oscillator.connect(gainNode);
    gainNode.connect(ctx.destination);

    oscillator.start(ctx.currentTime);
    oscillator.stop(ctx.currentTime + 0.15);
  } catch (e) {
    console.warn("Failed to play bell audio:", e);
  }
}
