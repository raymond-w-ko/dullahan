// Global state store for terminal windows and panes
// Provides reactive state management without heavy dependencies

import { debug } from "./debug";
import { TerminalConnection } from "./terminal/connection";
import { AUDIO } from "./constants";
import type { TerminalSnapshot, LayoutUpdate, WindowLayout, LayoutTemplate } from "./terminal/connection";
import * as config from "./config";
import { copyToClipboard, pasteFromClipboard } from "./terminal/clipboard";

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

/** Internal clipboard entry (for 'c' and 'p' clipboards) */
export interface ClipboardEntry {
  text: string;
  timestamp: number; // Date.now()
}

/** Toast notification (from OSC 9/777) */
export interface ToastNotification {
  id: string;
  paneId: number;
  title?: string;
  message: string;
  type: "info" | "success" | "warning" | "error";
  timestamp: number;
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

  // Internal clipboards (OSC 52)
  clipboardC: ClipboardEntry | null; // 'c' = system clipboard
  clipboardP: ClipboardEntry | null; // 'p' = primary selection

  // UI state
  bellActive: boolean;
  settingsOpen: boolean;
  fullscreenPaneId: number | null; // Pane ID in fullscreen, null if not fullscreen
  dimensionVersion: number; // Incremented when font settings change
  toasts: ToastNotification[]; // Active toast notifications

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

  clipboardC: null,
  clipboardP: null,

  bellActive: false,
  settingsOpen: false,
  fullscreenPaneId: null,
  dimensionVersion: 0, // Incremented when font settings change to trigger recalc
  toasts: [],

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

// ============================================================================
// Toast notifications
// ============================================================================

/** Infer toast type from message content */
function inferToastType(message: string, title?: string): ToastNotification["type"] {
  const text = `${title ?? ""} ${message}`.toLowerCase();
  if (text.includes("error") || text.includes("fail") || text.includes("fatal")) {
    return "error";
  }
  if (text.includes("warn")) {
    return "warning";
  }
  if (text.includes("success") || text.includes("done") || text.includes("complete")) {
    return "success";
  }
  return "info";
}

/** Add a toast notification */
export function addToast(paneId: number, title: string | undefined, message: string) {
  const toast: ToastNotification = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`,
    paneId,
    title,
    message,
    type: inferToastType(message, title),
    timestamp: Date.now(),
  };
  store.toasts = [...store.toasts, toast];
  notify();
  return toast.id;
}

/** Dismiss a toast by ID */
export function dismissToast(id: string) {
  store.toasts = store.toasts.filter((t) => t.id !== id);
  notify();
}

/** Clear all toasts */
export function clearAllToasts() {
  store.toasts = [];
  notify();
}

/** Get visible toasts (limited by max visible) */
export function getVisibleToasts(maxVisible: number): ToastNotification[] {
  return store.toasts.slice(-maxVisible);
}

export function setSettingsOpen(open: boolean) {
  store.settingsOpen = open;
  notify();
}

export function setFullscreenPane(paneId: number | null) {
  store.fullscreenPaneId = paneId;
  notify();
}

export function toggleFullscreen(paneId: number) {
  if (store.fullscreenPaneId === paneId) {
    store.fullscreenPaneId = null;
  } else {
    store.fullscreenPaneId = paneId;
  }
  notify();
}

export function isFullscreen(): boolean {
  return store.fullscreenPaneId !== null;
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

  // Collect all pane IDs from the new layout
  const activePaneIds = new Set<number>();
  for (const win of layout.windows) {
    for (const paneId of win.panes) {
      activePaneIds.add(paneId);
    }
  }

  // Remove panes that are no longer in any window
  for (const paneId of store.panes.keys()) {
    if (!activePaneIds.has(paneId)) {
      store.panes.delete(paneId);
    }
  }

  // Create pane states for any new panes we haven't seen
  for (const paneId of activePaneIds) {
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

// ============================================================================
// Clipboard helpers (internal OSC 52 clipboards)
// ============================================================================

/** Set the 'c' (system clipboard) internal buffer */
export function setClipboardC(text: string) {
  store.clipboardC = { text, timestamp: Date.now() };
  notify();
}

/** Set the 'p' (primary selection) internal buffer */
export function setClipboardP(text: string) {
  store.clipboardP = { text, timestamp: Date.now() };
  notify();
}

/** Get the most recently modified clipboard ('c' or 'p') */
export function getMostRecentClipboard(): ClipboardEntry | null {
  const c = store.clipboardC;
  const p = store.clipboardP;
  if (!c && !p) return null;
  if (!c) return p;
  if (!p) return c;
  return c.timestamp >= p.timestamp ? c : p;
}

/** Get clipboard by kind */
export function getClipboardByKind(kind: string): ClipboardEntry | null {
  if (kind === "c") return store.clipboardC;
  if (kind === "p") return store.clipboardP;
  return null;
}

/** Copy internal clipboard to navigator.clipboard */
export async function copyInternalToSystem(kind: "c" | "p"): Promise<boolean> {
  const entry = kind === "c" ? store.clipboardC : store.clipboardP;
  if (!entry) return false;
  try {
    await copyToClipboard(entry.text);
    debug.log(`Copied internal '${kind}' to system clipboard: ${entry.text.length} chars`);
    return true;
  } catch (err) {
    debug.warn(`Failed to copy '${kind}' to system clipboard:`, err);
    return false;
  }
}

/** Copy navigator.clipboard to internal clipboard */
export async function copySystemToInternal(kind: "c" | "p"): Promise<boolean> {
  try {
    const text = await pasteFromClipboard();
    if (kind === "c") {
      setClipboardC(text);
    } else {
      setClipboardP(text);
    }
    debug.log(`Copied system clipboard to internal '${kind}': ${text.length} chars`);
    return true;
  } catch (err) {
    debug.warn(`Failed to copy system clipboard to '${kind}':`, err);
    return false;
  }
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

  conn.on("toast", (paneId, title, message) => {
    addToast(paneId, title, message);
  });

  conn.on("masterChanged", (masterId, isMaster) => {
    setMasterState(masterId, isMaster);
  });

  conn.on("layout", (layout) => {
    setLayout(layout);
  });

  // OSC 52 clipboard handlers
  conn.on("clipboardSet", async (paneId, clipboard, base64Data) => {
    // Terminal wants to write to clipboard
    try {
      const text = atob(base64Data);
      const kind = clipboard.charAt(0) as "c" | "p";

      // Store in internal clipboard
      if (kind === "c") {
        setClipboardC(text);
      } else if (kind === "p") {
        setClipboardP(text);
      } else {
        // Unknown kind, default to 'c'
        setClipboardC(text);
      }

      debug.log(`Clipboard SET from pane ${paneId}: ${text.length} chars to '${clipboard}'`);
    } catch (err) {
      debug.warn("Clipboard SET failed:", err);
    }
  });

  conn.on("clipboardGet", async (paneId, clipboard) => {
    // Terminal wants to read from clipboard
    // Only master should respond to avoid race conditions
    if (!conn.isMaster) {
      debug.log(`Clipboard GET ignored (not master) for pane ${paneId}`);
      return;
    }

    const kind = clipboard.charAt(0);
    const entry = getClipboardByKind(kind);

    if (entry) {
      // Return from internal clipboard
      const base64Data = btoa(entry.text);
      conn.sendClipboardResponse(paneId, clipboard, base64Data);
      debug.log(`Clipboard GET for pane ${paneId}: sent ${entry.text.length} chars from internal '${kind}'`);
    } else {
      // Internal clipboard empty, try system clipboard as fallback
      try {
        const text = await pasteFromClipboard();
        const base64Data = btoa(text);
        conn.sendClipboardResponse(paneId, clipboard, base64Data);
        debug.log(`Clipboard GET for pane ${paneId}: sent ${text.length} chars from system clipboard (fallback)`);
      } catch (err) {
        debug.warn("Clipboard GET failed:", err);
        // Send empty response on failure so terminal doesn't hang
        conn.sendClipboardResponse(paneId, clipboard, "");
      }
    }
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
