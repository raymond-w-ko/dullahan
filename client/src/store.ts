// Global state store for terminal windows and panes
// Provides reactive state management without heavy dependencies

import { debug } from "./debug";
import { TerminalConnection } from "./terminal/connection";

const clipboardLog = debug.category('clipboard');
const storeLog = debug.category('store');
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

/** Progress bar state (from OSC 9;4) */
export interface ProgressState {
  paneId: number;
  state: number; // 0=hidden, 1=normal, 2=error, 3=indeterminate, 4=warning
  value: number; // 0-100
}

/** Context menu state for window tabs */
export interface WindowContextMenuState {
  kind: "window";
  /** X position in viewport pixels */
  x: number;
  /** Y position in viewport pixels */
  y: number;
  /** Window ID this menu is for */
  windowId: number;
}

/** Context menu state for pane titlebars */
export interface PaneContextMenuState {
  kind: "pane";
  /** X position in viewport pixels */
  x: number;
  /** Y position in viewport pixels */
  y: number;
  /** Window ID this pane belongs to */
  windowId: number;
  /** Pane ID this menu is for */
  paneId: number;
}

/** Hidden panes picker state (triggered by clicking +N indicator) */
export interface HiddenPanesPickerState {
  kind: "hidden_picker";
  /** X position in viewport pixels */
  x: number;
  /** Y position in viewport pixels */
  y: number;
  /** Window ID to show hidden panes for */
  windowId: number;
}

/** Union of all context menu states */
export type ContextMenuState = WindowContextMenuState | PaneContextMenuState | HiddenPanesPickerState;

export interface Store {
  // Connection state
  connection: TerminalConnection | null;
  connected: boolean;
  error: string | null;
  latency: number; // Server latency in ms (averaged over last 8 samples)

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
  progress: ProgressState | null; // Active progress bar
  contextMenu: ContextMenuState | null; // Context menu state

  // Config (mirrored from config module for reactivity)
  theme: string;
  cursorStyle: "block" | "bar" | "underline" | "block_hollow";
  cursorColor: string;
  cursorText: string;
  cursorBlink: "" | "true" | "false";
}

type Listener = () => void;

// Create initial pane state with default values
function createPaneState(id: number): PaneState {
  return {
    id,
    title: `Pane ${id}`,
    snapshot: null,
    syncStats: { deltas: 0, resyncs: 0, gen: 0 },
    isReadOnly: false,
    dimensions: { cols: 80, rows: 24 },
  };
}

// Global store instance
const store: Store = {
  connection: null,
  connected: false,
  error: null,
  latency: 0,

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
  progress: null,
  contextMenu: null,

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

export function setLatency(latency: number) {
  store.latency = latency;
  notify();
}

export function setPaneSnapshot(paneId: number, snapshot: TerminalSnapshot) {
  // Create pane if it doesn't exist (snapshots may arrive before layout)
  let pane = store.panes.get(paneId);
  if (!pane) {
    pane = createPaneState(paneId);
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

// ============================================================================
// Progress bar (OSC 9;4)
// ============================================================================

/** Set progress bar state */
export function setProgress(paneId: number, state: number, value: number) {
  if (state === 0) {
    // Hide progress
    store.progress = null;
  } else {
    store.progress = { paneId, state, value };
  }
  notify();
}

/** Get current progress state */
export function getProgress(): ProgressState | null {
  return store.progress;
}

export function setSettingsOpen(open: boolean) {
  store.settingsOpen = open;
  notify();
}

// ============================================================================
// Context menu
// ============================================================================

/** Open window context menu (right-click on window tab) */
export function openWindowContextMenu(windowId: number, x: number, y: number) {
  store.contextMenu = { kind: "window", windowId, x, y };
  notify();
}

/** Open pane context menu (right-click on pane titlebar) */
export function openPaneContextMenu(windowId: number, paneId: number, x: number, y: number) {
  store.contextMenu = { kind: "pane", windowId, paneId, x, y };
  notify();
}

/** Open hidden panes picker (click on +N indicator) */
export function openHiddenPanesPicker(windowId: number, x: number, y: number) {
  store.contextMenu = { kind: "hidden_picker", windowId, x, y };
  notify();
}

export function closeContextMenu() {
  store.contextMenu = null;
  notify();
}

export function setWindowLayout(windowId: number, templateId: string) {
  store.connection?.setWindowLayout(windowId, templateId);
  closeContextMenu();
}

/** Swap two panes' positions in a window */
export function swapPanes(windowId: number, paneId1: number, paneId2: number) {
  store.connection?.swapPanes(windowId, paneId1, paneId2);
  closeContextMenu();
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
      store.panes.set(paneId, createPaneState(paneId));
    }
  }

  notify();
}

export function switchWindow(windowId: number) {
  const window = store.windows.get(windowId);
  if (window) {
    store.activeWindowId = windowId;
    // Increment dimensionVersion to force pane dimension recalculation
    // This ensures panes recalculate their sizes when becoming visible
    store.dimensionVersion++;
    // Clear resize cache for panes in this window to ensure fresh calculations
    // are sent to the server, avoiding stale cached values
    if (store.connection) {
      store.connection.clearResizeCache(window.paneIds);
    }
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

/** Set both clipboards and sync to server (used by keybind copy action) */
export function setClipboardBothAndSync(text: string) {
  const timestamp = Date.now();
  store.clipboardC = { text, timestamp };
  store.clipboardP = { text, timestamp };
  notify();
  // Sync both to server
  syncClipboardToServer("c", text);
  syncClipboardToServer("p", text);
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
    clipboardLog.log(`Copied internal '${kind}' to system: ${entry.text.length} chars`);
    return true;
  } catch (err) {
    clipboardLog.warn(`Failed to copy '${kind}' to system:`, err);
    return false;
  }
}

/**
 * Paste from server's clipboard to the active terminal.
 * Sends clipboard_paste message to server which writes to PTY.
 */
export function pasteClipboardToTerminal(kind: "c" | "p"): void {
  const conn = store.connection;
  if (!conn || !conn.isConnected) {
    clipboardLog.warn("Cannot paste: not connected");
    return;
  }
  if (!conn.isMaster) {
    clipboardLog.warn("Cannot paste: not master");
    return;
  }
  const paneId = store.focusedPaneId;
  conn.sendClipboardPaste(paneId, kind);
  clipboardLog.log(`Pasting '${kind}' to pane ${paneId}`);
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
    // Sync to server so it persists across reconnects
    syncClipboardToServer(kind, text);
    clipboardLog.log(`Copied system to internal '${kind}': ${text.length} chars`);
    return true;
  } catch (err) {
    clipboardLog.warn(`Failed to copy system to '${kind}':`, err);
    return false;
  }
}

/** Sync clipboard to server for persistence across reconnects */
function syncClipboardToServer(kind: "c" | "p", text: string): void {
  const conn = store.connection;
  if (!conn || !conn.isConnected) return;
  try {
    const base64Data = btoa(text);
    conn.sendClipboardSet(kind, base64Data);
    clipboardLog.log(`Synced '${kind}' to server: ${text.length} chars`);
  } catch (err) {
    clipboardLog.warn(`Failed to sync '${kind}' to server:`, err);
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
  conn.on("disconnect", () => {
    setConnected(false);
    setLatency(0); // Reset latency on disconnect
  });
  conn.on("error", (err) => setError(err));
  conn.on("latency", (latency) => setLatency(latency));

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

  conn.on("progress", (paneId, state, value) => {
    setProgress(paneId, state, value);
  });

  conn.on("masterChanged", (masterId, isMaster) => {
    setMasterState(masterId, isMaster);
  });

  conn.on("layout", (layout) => {
    setLayout(layout);
  });

  // OSC 52 clipboard handlers
  conn.on("clipboardSet", async (paneId, clipboard, base64Data) => {
    // Terminal/server wants to update clipboard
    try {
      const text = atob(base64Data);
      const kind = clipboard.charAt(0) as "c" | "p";

      // Store in internal clipboard
      if (kind === "c") {
        setClipboardC(text);
        // Also write to navigator.clipboard for 'c' (system clipboard)
        // This ensures keybind copy updates the system clipboard
        try {
          await navigator.clipboard.writeText(text);
          clipboardLog.log(`SET: wrote ${text.length} chars to navigator.clipboard`);
        } catch (clipErr) {
          clipboardLog.warn("Failed to write to navigator.clipboard:", clipErr);
        }
      } else if (kind === "p") {
        // Primary selection only updates internal mirror, not navigator.clipboard
        setClipboardP(text);
      } else {
        // Unknown kind, default to 'c'
        setClipboardC(text);
      }

      clipboardLog.log(`SET from pane ${paneId}: ${text.length} chars to '${clipboard}'`);
    } catch (err) {
      clipboardLog.warn("SET failed:", err);
    }
  });

  conn.on("clipboardGet", async (paneId, clipboard) => {
    // Terminal wants to read from clipboard
    // Only master should respond to avoid race conditions
    if (!conn.isMaster) {
      clipboardLog.log(`GET ignored (not master) for pane ${paneId}`);
      return;
    }

    const kind = clipboard.charAt(0);
    const entry = getClipboardByKind(kind);

    if (entry) {
      // Return from internal clipboard
      const base64Data = btoa(entry.text);
      conn.sendClipboardResponse(paneId, clipboard, base64Data);
      clipboardLog.log(`GET pane ${paneId}: sent ${entry.text.length} chars from internal '${kind}'`);
    } else {
      // Internal clipboard empty, try system clipboard as fallback
      try {
        const text = await pasteFromClipboard();
        const base64Data = btoa(text);
        conn.sendClipboardResponse(paneId, clipboard, base64Data);
        clipboardLog.log(`GET pane ${paneId}: sent ${text.length} chars from system (fallback)`);
      } catch (err) {
        clipboardLog.warn("GET failed:", err);
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
    storeLog.warn("Failed to play bell audio:", e);
  }
}
