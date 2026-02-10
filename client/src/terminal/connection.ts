import { debug } from "../debug";
import { get as getConfig } from "../config";

// Category-scoped loggers for different subsystems
const connLog = debug.category('connection');
const snapshotLog = debug.category('snapshot');
const deltaLog = debug.category('delta');
const syncLog = debug.category('sync');
const resizeLog = debug.category('resize');
const layoutLog = debug.category('layout');
const shellLog = debug.category('shell');
// WebSocket connection to dullahan server
// Uses binary msgpack for efficient data transmission
// Messages are compressed with Snappy

import { decode } from "@msgpack/msgpack";
import { snappyUncompress } from "hysnappy";
import { v4 as uuidv4 } from "uuid";

/**
 * Read varint-encoded uncompressed length from Snappy data.
 * Snappy format: varint length prefix followed by compressed blocks.
 */
function readSnappyLength(data: Uint8Array): number {
  let result = 0;
  let shift = 0;
  const maxBytes = Math.min(data.length, 5);
  for (let i = 0; i < maxBytes; i++) {
    const byte = data[i]!;
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) {
      return result;
    }
    shift += 7;
  }
  throw new Error("Invalid varint in Snappy data");
}
import { cellToChar, ContentTag, Wide, decodeGraphemes, decodeHyperlinks, decodeCellsFromBytes, decodeRowIds } from "../../../protocol/schema/cell";
import type { Cell, GraphemeTable, HyperlinkTable } from "../../../protocol/schema/cell";
import { decodeStyleTableFromBytes } from "../../../protocol/schema/style";
import { calculateTerminalSize } from "./dimensions";
import type { StyleTable } from "../../../protocol/schema/style";
import type { KeyMessage } from "./keyboard";
import type { TextMessage } from "./ime";
import type { MouseMessage } from "./mouse";
import {
  canonicalizePayloadStyles,
  cloneStyleIdentityState,
  createStyleIdentityState,
  pruneUnusedStyles,
  remapCellsToCanonicalStyles,
  type StyleIdentityState,
} from "./styleIdentity";
import type {
  BinarySnapshot,
  BinaryDelta,
  TitleMessage,
  BellMessage,
  FocusServerMessage,
  MasterChangedMessage,
  WindowLayout,
  WindowInfo,
  LayoutTemplate,
  LayoutUpdate,
  LayoutMessage,
  ServerMessage,
  ClientMessage,
  DeltaUpdate,
  ScrollbackInfo,
  SelectionBounds,
  ShellIntegrationMessage,
} from "../../../protocol/schema/messages";

const INVALID_ROW_ID = 0xffffffffffffffffn;

export type {
  BinarySnapshot,
  BinaryDelta,
  WindowLayout,
  WindowInfo,
  LayoutTemplate,
  LayoutUpdate,
  ClientMessage,
  DeltaUpdate,
  ScrollbackInfo,
  SelectionBounds,
  GraphemeTable,
  HyperlinkTable,
};

// ============================================================================
// Typed EventEmitter (lightweight, zero dependencies)
// ============================================================================

type EventMap = Record<string, (...args: any[]) => void>;

class TypedEventEmitter<T extends EventMap> {
  private listeners = new Map<keyof T, Set<T[keyof T]>>();

  on<K extends keyof T>(event: K, callback: T[K]): void {
    let set = this.listeners.get(event);
    if (!set) {
      set = new Set();
      this.listeners.set(event, set);
    }
    set.add(callback);
  }

  off<K extends keyof T>(event: K, callback: T[K]): void {
    const set = this.listeners.get(event);
    if (set) {
      set.delete(callback);
    }
  }

  emit<K extends keyof T>(event: K, ...args: Parameters<T[K]>): void {
    const set = this.listeners.get(event);
    if (set) {
      for (const callback of set) {
        (callback as (...args: any[]) => void)(...args);
      }
    }
  }

  removeAllListeners(event?: keyof T): void {
    if (event) {
      this.listeners.delete(event);
    } else {
      this.listeners.clear();
    }
  }
}

// ============================================================================
// Connection Events
// ============================================================================

/** Events emitted by TerminalConnection */
export type ConnectionEvents = {
  snapshot: (snapshot: TerminalSnapshot) => void;
  delta: (delta: DeltaUpdate) => void;
  output: (data: string) => void;
  title: (paneId: number, title: string) => void;
  bell: () => void;
  toast: (paneId: number, title: string | undefined, message: string) => void;
  progress: (paneId: number, state: number, value: number) => void;
  shellIntegration: (
    paneId: number,
    event: "prompt_start" | "prompt_end" | "output_start" | "command_end",
    exitCode?: number
  ) => void;
  focus: (paneId: number) => void;
  connect: () => void;
  disconnect: () => void;
  error: (error: string) => void;
  masterChanged: (masterId: string | null, isMaster: boolean) => void;
  layout: (layout: LayoutUpdate) => void;
  clipboardSet: (paneId: number, clipboard: string, data: string) => void;
  clipboardGet: (paneId: number, clipboard: string) => void;
  latency: (latencyMs: number) => void;
};

// ============================================================================
// Terminal Types
// ============================================================================

export interface TerminalSnapshot {
  paneId: number; // Pane ID for multi-pane support
  gen: number; // Generation counter for delta sync
  cols: number;
  rows: number;
  cursor: {
    x: number;
    y: number;
    visible: boolean;
    style: "block" | "underline" | "bar";
    blink: boolean; // DEC Mode 12 (AT&T cursor blink) state from server
  };
  altScreen: boolean;
  scrollback: ScrollbackInfo;
  cells: Cell[]; // Decoded cell data
  styles: StyleTable; // Decoded style table
  rowIds: bigint[]; // Stable row IDs for delta sync (one per row)
  graphemes: GraphemeTable; // Grapheme data for multi-codepoint characters
  hyperlinks: HyperlinkTable; // Hyperlink data for OSC 8 links
  selection?: SelectionBounds; // Current selection (if any)
}

/** A cached row with LRU tracking */
interface CachedRow {
  cells: Cell[];
  lastAccess: number;  // Timestamp of last access
}

/** Per-pane state for delta sync tracking */
interface PaneState {
  generation: number;
  minRowId: bigint | null;
  rowCache: Map<bigint, CachedRow>;  // LRU-tracked row cache
  rowGraphemes: Map<bigint, GraphemeTable>; // Graphemes per row (row-relative indices)
  rowHyperlinks: Map<bigint, HyperlinkTable>; // Hyperlinks per row (row-relative indices)
  cols: number;
  rows: number;
  followTail: boolean; // Keep viewport pinned to bottom unless user scrolls up
  autoFollowInFlight: boolean; // Prevent repeated auto-follow scroll sends
  lastViewportTop: number | null;
  styleIdentity: StyleIdentityState;
  lastStyles: StyleTable | null;
  lastRowIds: bigint[] | null;
  lastGraphemes: GraphemeTable | null; // Last snapshot's graphemes (global indices)
  lastHyperlinks: HyperlinkTable | null; // Last snapshot's hyperlinks (global indices)
  deltaCount: number;
  resyncCount: number;
}

type ResyncReason = "cache_miss" | "style_miss" | "corruption" | "manual";

interface PendingResync {
  reason: ResyncReason;
  timer: number | null;
}

/** Storage key for client ID */
const CLIENT_ID_KEY = "dullahan_client_id";
const AUTH_TOKEN_KEY = "dullahan.authToken";

function readAuthTokenFromUrl(): string | null {
  try {
    const params = new URLSearchParams(window.location.search);
    const token = params.get("token");
    return token && token.length > 0 ? token : null;
  } catch {
    return null;
  }
}

function readAuthTokenFromStorage(): string | null {
  try {
    const token = localStorage.getItem(AUTH_TOKEN_KEY);
    return token && token.length > 0 ? token : null;
  } catch {
    return null;
  }
}

function writeAuthTokenToStorage(token: string): void {
  try {
    localStorage.setItem(AUTH_TOKEN_KEY, token);
  } catch {
    // Ignore storage errors (private mode, etc.)
  }
}

function getAuthToken(): string | null {
  const urlToken = readAuthTokenFromUrl();
  if (urlToken) {
    writeAuthTokenToStorage(urlToken);
    return urlToken;
  }
  return readAuthTokenFromStorage();
}

/** Get or generate client ID (persisted in sessionStorage) */
function getClientId(): string {
  let clientId = sessionStorage.getItem(CLIENT_ID_KEY);
  if (!clientId) {
    clientId = uuidv4();
    sessionStorage.setItem(CLIENT_ID_KEY, clientId);
    connLog.log("Generated new client ID:", clientId);
  }
  return clientId;
}

export class TerminalConnection {
  private ws: WebSocket | null = null;
  private url: string;
  private reconnectTimer: number | null = null;
  private reconnectAttempts: number = 0;

  // Client identification (persisted per session)
  private _clientId: string;
  private _authToken: string | null = null;

  // Master/slave state - tracks if this client is the master
  private _masterId: string | null = null;

  // Layout state - current window/pane mappings
  private _layout: LayoutUpdate | null = null;

  // Per-pane delta sync state
  private _panes: Map<number, PaneState> = new Map();

  // Pending resize tracking - resizes are queued and sent when connected
  private _pendingResizes: Map<number, { cols: number; rows: number; cellWidth: number; cellHeight: number }> = new Map();
  private _lastSentResizes: Map<number, { cols: number; rows: number; cellWidth: number; cellHeight: number }> = new Map();
  private _resizeDebounceTimer: number | null = null;
  private static readonly RESIZE_DEBOUNCE_MS = 333;

  // Resync debouncing - prevent resync storms
  private _lastResyncTime: Map<number, number> = new Map();
  private _pendingResync: Map<number, PendingResync> = new Map();
  private static readonly RESYNC_COOLDOWN_MS = 1000;

  // Latency tracking
  private _pingTimer: number | null = null;
  private _latencySamples: number[] = [];
  private _latency: number = 0;
  private static readonly PING_INTERVAL_MS = 250;
  private static readonly LATENCY_SAMPLE_COUNT = 8;

  // Outbound backpressure handling
  private _sendQueue: string[] = [];
  private _sendQueueBytes: number = 0;
  private _flushTimer: number | null = null;
  private static readonly MAX_BUFFERED_BYTES = 2 * 1024 * 1024;
  private static readonly MAX_QUEUE_BYTES = 4 * 1024 * 1024;
  private static readonly FLUSH_INTERVAL_MS = 50;

  // Event emitter for connection events
  private _emitter = new TypedEventEmitter<ConnectionEvents>();

  /** Subscribe to a connection event */
  on<K extends keyof ConnectionEvents>(event: K, callback: ConnectionEvents[K]): void {
    this._emitter.on(event, callback);
  }

  /** Unsubscribe from a connection event */
  off<K extends keyof ConnectionEvents>(event: K, callback: ConnectionEvents[K]): void {
    this._emitter.off(event, callback);
  }

  /** Emit an event (private) */
  private emit<K extends keyof ConnectionEvents>(
    event: K,
    ...args: Parameters<ConnectionEvents[K]>
  ): void {
    this._emitter.emit(event, ...args);
  }

  constructor(url?: string) {
    // Get or generate client ID
    this._clientId = getClientId();
    this._authToken = getAuthToken();

    if (url) {
      this.url = url;
    } else {
      // Derive WebSocket URL from current page origin
      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      this.url = `${protocol}//${window.location.host}`;
    }
  }

  /** Get this client's unique ID */
  get clientId(): string {
    return this._clientId;
  }

  /** Check if this client is the current master */
  get isMaster(): boolean {
    return this._masterId !== null && this._masterId === this._clientId;
  }

  /** Get the current master's ID (or null if no master) */
  get masterId(): string | null {
    return this._masterId;
  }

  /** Get the current layout (or null if not received yet) */
  get layout(): LayoutUpdate | null {
    return this._layout;
  }

  /** Get the current average latency in ms (0 if not yet measured) */
  get latency(): number {
    return this._latency;
  }

  /** Get or create pane state */
  private getPaneState(paneId: number): PaneState {
    let state = this._panes.get(paneId);
    if (!state) {
      state = {
        generation: 0,
        minRowId: null,
        rowCache: new Map(),
        rowGraphemes: new Map(),
        rowHyperlinks: new Map(),
        cols: 80,
        rows: 24,
        followTail: true,
        autoFollowInFlight: false,
        lastViewportTop: null,
        styleIdentity: createStyleIdentityState(),
        lastStyles: null,
        lastRowIds: null,
        lastGraphemes: null,
        lastHyperlinks: null,
        deltaCount: 0,
        resyncCount: 0,
      };
      this._panes.set(paneId, state);
    }
    return state;
  }

  /** Current generation for a pane (for sync requests) */
  getGeneration(paneId: number): number {
    return this._panes.get(paneId)?.generation ?? 0;
  }

  /** Oldest row ID in cache for a pane (for sync requests) */
  getMinRowId(paneId: number): bigint {
    return this._panes.get(paneId)?.minRowId ?? 0n;
  }

  /** Debug stats: number of delta updates received for a pane */
  getDeltaCount(paneId: number): number {
    return this._panes.get(paneId)?.deltaCount ?? 0;
  }

  /** Debug stats: number of full resyncs for a pane */
  getResyncCount(paneId: number): number {
    return this._panes.get(paneId)?.resyncCount ?? 0;
  }

  /** Sum a numeric property across all panes */
  private _sumPaneProperty(prop: keyof PaneState): number {
    let total = 0;
    for (const pane of this._panes.values()) {
      total += pane[prop] as number;
    }
    return total;
  }

  /** Total delta count across all panes */
  get totalDeltaCount(): number {
    return this._sumPaneProperty("deltaCount");
  }

  /** Total resync count across all panes */
  get totalResyncCount(): number {
    return this._sumPaneProperty("resyncCount");
  }

  /** Get cached row by ID for a pane, or undefined if not cached */
  getCachedRow(paneId: number, rowId: bigint): Cell[] | undefined {
    const cached = this._panes.get(paneId)?.rowCache.get(rowId);
    return cached?.cells;
  }

  connect(): void {
    this._authToken = getAuthToken();
    if (!this._authToken) {
      connLog.warn("Auth token missing; skipping WebSocket connect");
      this.emit("error", "Missing auth token. Add ?token=... to the URL.");
      return;
    }

    if (this.ws) {
      this.ws.close();
    }

    connLog.log(`Connecting to ${this.url}...`);
    this.ws = new WebSocket(this.url);

    this.ws.onopen = () => {
      connLog.log("WebSocket connected");
      // Reset reconnect backoff on successful connection
      this.reconnectAttempts = 0;
      // Send hello message to identify this client with theme info
      this.sendHello("connect");
      // Flush any pending resizes now that we're connected
      this.flushPendingResizes();
      // Flush any queued outbound messages
      this.flushSendQueue();
      // Start latency pings
      this.startPingTimer();
      this.emit("connect");
    };

    this.ws.onclose = (event) => {
      const detail = {
        code: event.code,
        reason: event.reason,
        wasClean: event.wasClean,
        url: this.ws?.url ?? this.url,
        readyState: this.ws?.readyState,
        reconnectAttempts: this.reconnectAttempts,
        clientId: this._clientId,
        masterId: this._masterId,
      };
      const error = new Error(`WebSocket disconnected (code ${event.code})`);
      connLog.error("WebSocket disconnected:", detail, event);
      if (error.stack) connLog.error("WebSocket disconnect stack:", error.stack);
      // Stop latency pings
      this.stopPingTimer();
      // Drop any queued outbound messages
      this.clearSendQueue();
      this.emit("disconnect");
      this.scheduleReconnect();
    };

    this.ws.onerror = (event) => {
      connLog.error("WebSocket error:", event);
      this.emit("error", "Connection error");
    };

    this.ws.binaryType = "arraybuffer";

    this.ws.onmessage = (event) => {
      try {
        if (event.data instanceof ArrayBuffer) {
          // Check compression header byte
          const data = new Uint8Array(event.data);
          const isCompressed = data[0] === 1;
          const payload = data.slice(1);
          
          // Decompress if needed, then decode msgpack
          const decompressed = isCompressed
            ? snappyUncompress(payload, readSnappyLength(payload))
            : payload;
          const msg = decode(decompressed) as ServerMessage;
          // Log raw message keys for debugging
          if (msg && typeof msg === 'object') {
            syncLog.log(`Received ${(msg as any).type} message, keys:`, Object.keys(msg));
          }
          this.handleBinaryMessage(msg);
        } else {
          // Legacy JSON message (shouldn't happen with new server)
          connLog.warn("Received text message, expected binary");
        }
      } catch (e) {
        connLog.error("Failed to parse message:", e);
      }
    };
  }

  /** Resend hello with updated theme info (used on theme changes). */
  sendThemeUpdate(): void {
    if (!this.isConnected) {
      return;
    }
    if (!this.isMaster) {
      connLog.log("Skipping theme hello (not master)");
      return;
    }
    this.sendHello("theme-update");
  }

  /** Send hello with logging (used on connect and theme updates). */
  private sendHello(reason: "connect" | "theme-update"): void {
    const themeInfo = this.getThemeInfo();
    const msg: ClientMessage = {
      type: "hello",
      clientId: this._clientId,
      ...themeInfo,
    };
    if (this._authToken) {
      msg.token = this._authToken;
    }
    this.send(msg);
    connLog.log(`Sent hello (${reason}) with client ID:`, this._clientId, "theme:", themeInfo);
  }

  private handleBinaryMessage(msg: ServerMessage): void {
    // Log all message types for debugging
    if (msg.type !== "snapshot" && msg.type !== "delta") {
      syncLog.log("Received message type:", msg.type);
    }
    switch (msg.type) {
      case "snapshot": {
        const paneId = msg.paneId;
        const paneState = this.getPaneState(paneId);

        snapshotLog.log(`Pane ${paneId}:`, msg.cols, "x", msg.rows,
          "scrollback:", msg.scrollback.totalRows, "top:", msg.scrollback.viewportTop);

        // Decode cells, styles, row IDs, graphemes, and hyperlinks from raw bytes
        const cells = decodeCellsFromBytes(msg.cells);
        const payloadStyles = decodeStyleTableFromBytes(msg.styles);
        const rowIds = decodeRowIds(msg.rowIds);
        const graphemes = msg.graphemes ? decodeGraphemes(msg.graphemes) : new Map();
        const hyperlinks = msg.hyperlinks ? decodeHyperlinks(msg.hyperlinks) : new Map();

        // Validate snapshot style table integrity before mutating pane state.
        const missingStyles = new Set<number>();
        for (const cell of cells) {
          if (cell.styleId !== 0 && !payloadStyles.has(cell.styleId)) {
            missingStyles.add(cell.styleId);
          }
        }
        if (missingStyles.size > 0) {
          snapshotLog.warn(`Pane ${paneId}: snapshot missing ${missingStyles.size} styles, requesting resync`);
          this.requestResync(paneId, "style_miss");
          return; // Don't emit or cache corrupted snapshot
        }

        // Canonicalize payload-local style IDs by style bytes so style semantics
        // remain stable even when server-side numeric IDs alias across pages.
        const styles: StyleTable = new Map();
        const styleIdentity = createStyleIdentityState();
        const payloadToCanonical = canonicalizePayloadStyles(payloadStyles, styles, styleIdentity);
        const remapMisses = remapCellsToCanonicalStyles(cells, payloadToCanonical);
        if (remapMisses > 0) {
          snapshotLog.warn(`Pane ${paneId}: snapshot had ${remapMisses} unmapped styles after canonicalization, requesting resync`);
          this.requestResync(paneId, "style_miss");
          return;
        }

        const snapshot: TerminalSnapshot = {
          paneId,
          gen: msg.gen,
          cols: msg.cols,
          rows: msg.rows,
          cursor: {
            x: msg.cursor.x,
            y: msg.cursor.y,
            visible: msg.cursor.visible,
            style: msg.cursor.style as "block" | "underline" | "bar",
            blink: msg.cursor.blink ?? true, // Default to true (blinking) if not sent
          },
          altScreen: msg.altScreen,
          scrollback: msg.scrollback,
          cells,
          styles,
          rowIds,
          graphemes,
          hyperlinks,
          selection: msg.selection,
        };

        // Update pane state from snapshot
        paneState.generation = msg.gen;
        paneState.cols = msg.cols;
        paneState.rows = msg.rows;
        paneState.resyncCount++;

        // Rebuild row cache, graphemes, and hyperlinks from snapshot.
        // INVALID_ROW_ID is an explicit "no row available" sentinel from server.
        paneState.rowCache.clear();
        paneState.rowGraphemes.clear();
        paneState.rowHyperlinks.clear();
        const now = Date.now();
        let minSeen = -1n;  // Use -1n as "not set" since row IDs are unsigned
        for (let y = 0; y < msg.rows; y++) {
          const rowId = rowIds[y];
          if (rowId !== undefined && rowId !== INVALID_ROW_ID) {
            const rowCells = cells.slice(y * msg.cols, (y + 1) * msg.cols);
            paneState.rowCache.set(rowId, { cells: rowCells, lastAccess: now });
            // Track minimum row ID
            if (minSeen < 0n || rowId < minSeen) {
              minSeen = rowId;
            }

            // Extract per-row graphemes (convert global cell indices to row-relative)
            const rowGraphemes: GraphemeTable = new Map();
            const rowStart = y * msg.cols;
            const rowEnd = rowStart + msg.cols;
            for (const [cellIndex, cps] of graphemes) {
              if (cellIndex >= rowStart && cellIndex < rowEnd) {
                rowGraphemes.set(cellIndex - rowStart, cps);
              }
            }
            if (rowGraphemes.size > 0) {
              paneState.rowGraphemes.set(rowId, rowGraphemes);
            }

            // Extract per-row hyperlinks (convert global cell indices to row-relative)
            const rowHyperlinks: HyperlinkTable = new Map();
            for (const [cellIndex, url] of hyperlinks) {
              if (cellIndex >= rowStart && cellIndex < rowEnd) {
                rowHyperlinks.set(cellIndex - rowStart, url);
              }
            }
            if (rowHyperlinks.size > 0) {
              paneState.rowHyperlinks.set(rowId, rowHyperlinks);
            }
          }
        }
        paneState.minRowId = minSeen >= 0n ? minSeen : null;

        // Save for delta merging
        paneState.styleIdentity = styleIdentity;
        paneState.lastStyles = styles;
        paneState.lastRowIds = rowIds;
        paneState.lastGraphemes = graphemes;
        paneState.lastHyperlinks = hyperlinks;
        this.maybeFollowViewportTail(paneId, paneState, msg.scrollback, msg.rows);

        snapshotLog.log(`Pane ${paneId}: stored ${paneState.rowCache.size} rows, ${graphemes.size} graphemes, ${hyperlinks.size} hyperlinks`);

        this.emit("snapshot", snapshot);

        // Extract title from snapshot if present
        const snapshotTitle = (msg as any).title;
        if (snapshotTitle && typeof snapshotTitle === 'string') {
          snapshotLog.log(`Pane ${paneId} title:`, snapshotTitle);
          this.emit("title", paneId, snapshotTitle);
        }
        break;
      }
      case "delta": {
        const paneId = msg.paneId;
        const paneState = this.getPaneState(paneId);

        deltaLog.log(`Pane ${paneId}: gen ${msg.fromGen} -> ${msg.gen}`);

        // Check if we can apply this delta
        // Client must be at fromGen to apply delta that brings us to gen
        if (paneState.generation === msg.fromGen) {
          this.applyDelta(msg, paneState);
        } else if (paneState.generation < msg.fromGen) {
          // We're behind - request full snapshot
          syncLog.log(`Pane ${paneId}: Delta fromGen ${msg.fromGen} > our gen ${paneState.generation}, requesting snapshot`);
          paneState.resyncCount++;
          this.sendSync(paneId, paneState.generation, Number(paneState.minRowId ?? 0n));
        } else {
          // We're ahead of fromGen - this delta is stale, ignore it
          // But if we're behind the target gen, request sync
          if (paneState.generation < msg.gen) {
            syncLog.log(`Pane ${paneId}: Stale delta (fromGen ${msg.fromGen} < our gen ${paneState.generation}), but behind target ${msg.gen}, requesting sync`);
            paneState.resyncCount++;
            this.sendSync(paneId, paneState.generation, Number(paneState.minRowId ?? 0n));
          } else {
            syncLog.log(`Pane ${paneId}: Stale delta ignored (fromGen ${msg.fromGen}, our gen ${paneState.generation})`);
          }
        }
        break;
      }
      case "output":
        this.emit("output", msg.data);
        break;
      case "title":
        syncLog.log(`Pane ${msg.paneId} title:`, msg.title);
        this.emit("title", msg.paneId, msg.title);
        break;
      case "bell":
        syncLog.log("Bell received");
        this.emit("bell");
        break;
      case "toast":
        syncLog.log(`Pane ${msg.paneId} toast:`, msg.title, msg.message);
        this.emit("toast", msg.paneId, msg.title, msg.message);
        break;
      case "progress":
        syncLog.log(`Pane ${msg.paneId} progress:`, msg.state, msg.value);
        this.emit("progress", msg.paneId, msg.state, msg.value);
        break;
      case "shell_integration": {
        // OSC 133 shell integration event
        const exitStr = msg.exitCode !== undefined ? ` exit=${msg.exitCode}` : "";
        shellLog.log(`pane=${msg.paneId} event=${msg.event}${exitStr}`);
        this.emit("shellIntegration", msg.paneId, msg.event, msg.exitCode);
        break;
      }
      case "focus":
        syncLog.log(`Focus pane: ${msg.paneId}`);
        this.emit("focus", msg.paneId);
        break;
      case "master_changed": {
        this._masterId = msg.masterId;
        const isMaster = this._masterId !== null && this._masterId === this._clientId;
        connLog.log("Master changed:", msg.masterId, "isMaster:", isMaster);
        this.emit("masterChanged", msg.masterId, isMaster);
        break;
      }
      case "layout": {
        // Extract layout info from windows
        const windows: WindowInfo[] = msg.windows.map((w: WindowInfo) => ({
          id: w.id,
          activePaneId: w.activePaneId,
          panes: w.panes,
          layout: w.layout,
        }));
        this._layout = {
          activeWindowId: msg.activeWindowId,
          windows,
          templates: msg.templates,
        };
        layoutLog.log(`Received: ${msg.windows.length} windows, active: ${msg.activeWindowId}`);
        for (const win of windows) {
          if (win.layout?.nodes) {
            const dims = win.layout.nodes.map((n: { width: number; height: number }) =>
              `${n.width.toFixed(1)}x${n.height.toFixed(1)}`
            ).join(", ");
            layoutLog.log(`Window ${win.id}: [${dims}]`);
          }
        }
        this.emit("layout", this._layout);
        break;
      }
      case "pong":
        // Handle latency measurement
        if (typeof msg.ts === "number") {
          this.handlePong(msg.ts);
        }
        break;
      case "clipboard":
        // OSC 52 clipboard operation from terminal
        if (msg.operation === "set") {
          // Terminal wants to write to system clipboard
          this.emit("clipboardSet", msg.paneId, msg.clipboard, msg.data ?? "");
        } else {
          // Terminal wants to read from system clipboard
          this.emit("clipboardGet", msg.paneId, msg.clipboard);
        }
        break;
    }
  }

  private scheduleReconnect(): void {
    this._authToken = getAuthToken();
    if (!this._authToken) {
      connLog.warn("Auth token missing; reconnect disabled");
      this.emit("error", "Missing auth token. Add ?token=... to the URL.");
      return;
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
    }
    // Exponential backoff: 250ms, 500ms, 1s, 2s, 4s (cap at 5s)
    const baseDelay = 250;
    const delay = Math.min(baseDelay * Math.pow(2, this.reconnectAttempts), 5000);
    this.reconnectAttempts++;
    connLog.log(`Scheduling reconnect in ${delay}ms (attempt ${this.reconnectAttempts})`);
    this.reconnectTimer = window.setTimeout(() => {
      connLog.log("Attempting to reconnect...");
      this.connect();
    }, delay);
  }

  disconnect(): void {
    this.stopPingTimer();
    this.clearSendQueue();
    this.clearPendingResyncs();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this._resizeDebounceTimer !== null) {
      clearTimeout(this._resizeDebounceTimer);
      this._resizeDebounceTimer = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  /**
   * Send keyboard event (full fidelity for Kitty protocol support)
   * Only master can send input.
   */
  sendKey(message: KeyMessage): void {
    if (!this.isMaster) return;
    this.send(message);
  }

  /**
   * Send composed text (IME input)
   * Only master can send input.
   */
  sendText(message: TextMessage): void {
    if (!this.isMaster) return;
    this.send(message);
  }

  /**
   * Send mouse event (for terminal mouse reporting protocols)
   * Only master can send input.
   */
  sendMouse(message: MouseMessage): void {
    if (!this.isMaster) return;
    this.send(message);
  }

  /**
   * Send resize for a specific pane (immediate, bypasses pending queue)
   * Only master can resize.
   */
  sendResize(paneId: number, cols: number, rows: number, cellWidth: number, cellHeight: number): void {
    if (!this.isMaster) return;
    this.send({ type: "resize", paneId, cols, rows, cellWidth, cellHeight });
  }

  /**
   * Calculate pane dimensions from a container element.
   * Returns { cols, rows } or { cols: -1, rows: -1 } if not ready (no measurement possible).
   * This is synchronous and does not send anything.
   *
   * Uses a persistent measurement element (.terminal-measure) that stays in the DOM
   * for efficiency and debuggability in Chrome DevTools.
   */
  calculatePaneSize(container: HTMLElement): { cols: number; rows: number; cellWidth: number; cellHeight: number } {
    const { cols, rows, cellWidth, cellHeight } = calculateTerminalSize(container);
    return { cols, rows, cellWidth, cellHeight };
  }

  /**
   * Mark that a pane needs to be resized.
   * Does not send immediately - call flushPendingResizes() or wait for connection.
   * Skips if dimensions match last sent values.
   */
  setPaneSize(paneId: number, cols: number, rows: number, cellWidth: number, cellHeight: number): void {
    // Skip if not ready
    if (cols < 0 || rows < 0) {
      return;
    }

    // Skip if same as last sent
    const lastSent = this._lastSentResizes.get(paneId);
    if (
      lastSent &&
      lastSent.cols === cols &&
      lastSent.rows === rows &&
      lastSent.cellWidth === cellWidth &&
      lastSent.cellHeight === cellHeight
    ) {
      return;
    }

    // Queue the resize
    resizeLog.log(
      `Queued pane ${paneId}: ${cols}x${rows} (cell ${cellWidth.toFixed(2)}x${cellHeight.toFixed(2)})`
    );
    this._pendingResizes.set(paneId, { cols, rows, cellWidth, cellHeight });

    // Schedule debounced flush to avoid resize cascades in dev builds
    this.scheduleResizeFlush();
  }

  /**
   * Schedule a debounced flush of pending resizes.
   * Waits RESIZE_DEBOUNCE_MS after the last call before actually flushing.
   */
  private scheduleResizeFlush(): void {
    if (this._resizeDebounceTimer !== null) {
      window.clearTimeout(this._resizeDebounceTimer);
    }
    this._resizeDebounceTimer = window.setTimeout(() => {
      this._resizeDebounceTimer = null;
      this.flushPendingResizes();
    }, TerminalConnection.RESIZE_DEBOUNCE_MS);
  }

  /**
   * Send all pending resizes if connected.
   * Safe to call at any time - does nothing if not connected or no pending resizes.
   * Only master can resize.
   */
  flushPendingResizes(): void {
    if (!this.isConnected || this._pendingResizes.size === 0 || !this.isMaster) {
      return;
    }

    for (const [paneId, size] of this._pendingResizes) {
      resizeLog.log(
        `Sending pane ${paneId}: ${size.cols}x${size.rows} (cell ${size.cellWidth.toFixed(2)}x${size.cellHeight.toFixed(2)})`
      );
      this.send({
        type: "resize",
        paneId,
        cols: size.cols,
        rows: size.rows,
        cellWidth: size.cellWidth,
        cellHeight: size.cellHeight,
      });
      this._lastSentResizes.set(paneId, size);
    }
    this._pendingResizes.clear();
  }

  /**
   * Clear the resize cache for all or specific panes.
   * This forces the next resize calculation to always send to the server,
   * even if the dimensions haven't changed. Useful when switching windows
   * or when layout changes significantly.
   * @param paneIds If provided, only clear cache for these panes. Otherwise clear all.
   */
  clearResizeCache(paneIds?: number[]): void {
    if (paneIds) {
      for (const paneId of paneIds) {
        this._lastSentResizes.delete(paneId);
        this._pendingResizes.delete(paneId);
      }
      resizeLog.log(`Cleared cache for panes: ${paneIds.join(", ")}`);
    } else {
      this._lastSentResizes.clear();
      this._pendingResizes.clear();
      resizeLog.log("Cleared all resize cache");
    }
  }

  /**
   * Scroll the terminal viewport by delta rows.
   * Negative values scroll up (toward history), positive scroll down.
   * Only master can scroll.
   */
  sendScroll(paneId: number, delta: number): void {
    if (!this.isMaster || delta === 0) return;
    const paneState = this.getPaneState(paneId);
    if (delta < 0) {
      // User intentionally scrolled up into history: stop tail-following until
      // we naturally reach bottom again.
      paneState.followTail = false;
      paneState.autoFollowInFlight = false;
    }
    this.send({ type: "scroll", paneId, delta });
  }

  /**
   * Keep viewport anchored to bottom when tail-following is enabled.
   * This corrects rare viewport drift during rapid TUI redraw/delete-line bursts.
   */
  private maybeFollowViewportTail(
    paneId: number,
    paneState: PaneState,
    scrollback: ScrollbackInfo,
    rows: number
  ): void {
    const viewportTop = Math.max(0, scrollback.viewportTop);
    const bottomTop = Math.max(0, scrollback.totalRows - rows);
    const atBottom = viewportTop >= bottomTop;

    const viewportMoved =
      paneState.lastViewportTop === null || paneState.lastViewportTop !== viewportTop;
    paneState.lastViewportTop = viewportTop;
    if (viewportMoved) {
      paneState.autoFollowInFlight = false;
    }

    if (atBottom) {
      paneState.followTail = true;
      paneState.autoFollowInFlight = false;
      return;
    }

    if (!paneState.followTail || paneState.autoFollowInFlight || !this.isMaster) {
      return;
    }

    const delta = bottomTop - viewportTop;
    if (delta <= 0) {
      return;
    }

    paneState.autoFollowInFlight = true;
    deltaLog.log(`Pane ${paneId}: auto-following tail by ${delta} rows`);
    this.send({ type: "scroll", paneId, delta });
  }

  /**
   * Switch focus to a specific pane
   */
  sendFocus(paneId: number): void {
    this.send({ type: "focus", paneId });
  }

  /**
   * Request to become the master client.
   * Only one client can be master at a time. The master can perform
   * privileged operations like resize, create panes, move panes.
   */
  requestMaster(): void {
    connLog.log("Requesting master status");
    this.send({ type: "request_master" });
  }

  /**
   * Create a new window with default panes.
   * Only the master client can create windows. Non-masters will have
   * their requests silently ignored by the server.
   * @param templateId Optional layout template ID (e.g., "2-col", "2x2", "single")
   */
  createWindow(templateId?: string): void {
    layoutLog.log("Creating window", templateId ? `template: ${templateId}` : "");
    this.send({ type: "new_window", templateId });
  }

  /**
   * Close a window and all its panes.
   * Only the master client can close windows. Non-masters will have
   * their requests silently ignored by the server.
   * The server will refuse to close the last remaining window.
   * @param windowId The ID of the window to close
   */
  closeWindow(windowId: number): void {
    if (!this.isMaster) return;
    layoutLog.log("Closing window:", windowId);
    this.send({ type: "close_window", windowId });
  }

  /**
   * Close a pane.
   * Only the master client can close panes. Non-masters will have
   * their requests silently ignored by the server.
   * If this is the last pane in a window, the window will be closed.
   * The server will refuse to close the last pane in the last window.
   * @param paneId The ID of the pane to close
   */
  closePane(paneId: number): void {
    if (!this.isMaster) return;
    layoutLog.log("Closing pane:", paneId);
    this.send({ type: "close_pane", paneId });
  }

  /**
   * Change a window's layout to a different template.
   * Only the master client can change layouts. Non-masters will have
   * their requests silently ignored by the server.
   * @param windowId The ID of the window to change
   * @param templateId The layout template ID (e.g., "2-col", "2x2", "single")
   */
  setWindowLayout(windowId: number, templateId: string): void {
    if (!this.isMaster) return;
    layoutLog.log(`Window ${windowId} -> template: ${templateId}`);
    this.send({ type: "set_layout", windowId, templateId });
  }

  /**
   * Resize layout nodes (update pane sizes from divider drag).
   * Only the master client can resize layouts.
   * @param windowId The ID of the window to resize
   * @param nodes The full updated layout tree with new dimensions
   */
  resizeLayout(windowId: number, nodes: import("../../../protocol/schema/layout").LayoutNode[]): void {
    if (!this.isMaster) return;
    layoutLog.log(`Resizing window ${windowId}`);
    this.send({ type: "resize_layout", windowId, nodes });
  }

  /**
   * Swap two panes' positions in a window's pane list.
   * This affects which panes are visible vs hidden when using smaller layouts.
   * Only the master client can swap panes.
   * @param windowId The ID of the window containing the panes
   * @param paneId1 First pane ID to swap
   * @param paneId2 Second pane ID to swap
   */
  swapPanes(windowId: number, paneId1: number, paneId2: number): void {
    if (!this.isMaster) return;
    layoutLog.log(`Window ${windowId}: swap panes ${paneId1} <-> ${paneId2}`);
    this.send({ type: "swap_panes", windowId, paneId1, paneId2 });
  }

  sendPing(): void {
    this.send({ type: "ping", ts: performance.now() });
  }

  /** Start periodic ping timer for latency measurement */
  private startPingTimer(): void {
    this.stopPingTimer();
    this._latencySamples = [];
    this._latency = 0;
    this._pingTimer = window.setInterval(() => {
      this.sendPing();
    }, TerminalConnection.PING_INTERVAL_MS);
    // Send first ping immediately
    this.sendPing();
  }

  /** Stop periodic ping timer */
  private stopPingTimer(): void {
    if (this._pingTimer !== null) {
      window.clearInterval(this._pingTimer);
      this._pingTimer = null;
    }
  }

  /** Handle pong response and update latency */
  private handlePong(ts: number): void {
    const now = performance.now();
    const latency = now - ts;

    // Add sample to circular buffer
    this._latencySamples.push(latency);
    if (this._latencySamples.length > TerminalConnection.LATENCY_SAMPLE_COUNT) {
      this._latencySamples.shift();
    }

    // Calculate average
    const sum = this._latencySamples.reduce((a, b) => a + b, 0);
    this._latency = Math.round(sum / this._latencySamples.length);

    this.emit("latency", this._latency);
  }

  /**
   * Send clipboard data back to server (for OSC 52 GET requests).
   * @param paneId Target pane that requested clipboard
   * @param clipboard Clipboard kind ('c', 's', or 'p')
   * @param data Base64-encoded clipboard contents
   */
  sendClipboardResponse(paneId: number, clipboard: string, data: string): void {
    this.send({ type: "clipboard_response", paneId, clipboard, data });
  }

  /**
   * Request server to copy selection to clipboard.
   * Server extracts selection text and broadcasts to all clients.
   * Only master can copy.
   */
  sendCopy(paneId: number): void {
    if (!this.isMaster) return;
    this.send({ type: "copy", paneId });
  }

  /**
   * Request server to paste from clipboard to PTY.
   * Server reads from its clipboard and writes to PTY with bracketed paste.
   * Only master can paste.
   * @param paneId Target pane to paste into
   * @param clipboard Which clipboard to paste from ('c' or 'p')
   */
  sendClipboardPaste(paneId: number, clipboard: "c" | "p"): void {
    if (!this.isMaster) return;
    this.send({ type: "clipboard_paste", paneId, clipboard });
  }

  /**
   * Set clipboard on server (sync from client).
   * Used to persist clipboard state to server.
   * @param clipboard Which clipboard to set ('c' or 'p')
   * @param data Base64-encoded text
   */
  sendClipboardSet(clipboard: "c" | "p", data: string): void {
    this.send({ type: "clipboard_set", clipboard, data });
  }

  /**
   * Request delta update from server for a specific pane.
   * @param paneId Target pane ID
   * @param gen Client's current generation for this pane
   * @param minRowId Oldest row ID client has cached for this pane
   */
  sendSync(paneId: number, gen: number, minRowId: number): void {
    this.send({ type: "sync", paneId, gen, minRowId });
  }

  /**
   * Request full resync from server when cache miss or corruption detected.
   * Debounced to prevent resync storms.
   * @param paneId Target pane ID
   * @param reason Why resync is needed (for logging/metrics)
   */
  requestResync(paneId: number, reason: ResyncReason): void {
    const now = Date.now();
    const lastResync = this._lastResyncTime.get(paneId) ?? 0;
    const elapsed = now - lastResync;
    const bypassCooldown = reason === "corruption" || reason === "style_miss";

    if (!bypassCooldown && elapsed < TerminalConnection.RESYNC_COOLDOWN_MS) {
      const delayMs = TerminalConnection.RESYNC_COOLDOWN_MS - elapsed;
      const pending = this._pendingResync.get(paneId);
      if (pending) {
        if (this.resyncReasonPriority(reason) > this.resyncReasonPriority(pending.reason)) {
          pending.reason = reason;
        }
        deltaLog.log(`Pane ${paneId}: resync throttled (${reason}), pending in ${delayMs}ms`);
        return;
      }

      const timer = window.setTimeout(() => {
        const queued = this._pendingResync.get(paneId);
        if (!queued) return;
        queued.timer = null;
        this._pendingResync.delete(paneId);
        this.requestResync(paneId, queued.reason);
      }, delayMs);
      this._pendingResync.set(paneId, { reason, timer });
      deltaLog.log(`Pane ${paneId}: resync throttled (${reason}), queued in ${delayMs}ms`);
      return;
    }

    // Immediate dispatch clears stale queued resyncs for this pane.
    const pending = this._pendingResync.get(paneId);
    if (pending && pending.timer !== null) {
      window.clearTimeout(pending.timer);
    }
    this._pendingResync.delete(paneId);

    this._lastResyncTime.set(paneId, now);
    deltaLog.warn(`Pane ${paneId}: requesting resync (${reason})`);
    this.send({ type: "resync", paneId, reason });

    // Track for debug UI
    const paneState = this._panes.get(paneId);
    if (paneState) {
      paneState.resyncCount++;
    }
  }

  private resyncReasonPriority(reason: ResyncReason): number {
    switch (reason) {
      case "corruption":
        return 3;
      case "style_miss":
        return 2;
      case "cache_miss":
        return 1;
      case "manual":
        return 0;
    }
  }

  private clearPendingResyncs(): void {
    for (const pending of this._pendingResync.values()) {
      if (pending.timer !== null) {
        window.clearTimeout(pending.timer);
      }
    }
    this._pendingResync.clear();
  }

  /**
   * Request sync for all panes
   */
  requestSyncAll(): void {
    for (const [paneId, state] of this._panes) {
      this.sendSync(paneId, state.generation, Number(state.minRowId ?? 0n));
    }
  }

  /**
   * Select all content in a pane.
   * Only master can select.
   */
  selectAll(paneId: number): void {
    if (!this.isMaster) return;
    this.send({ type: "select_all", paneId });
  }

  /**
   * Clear selection in a pane.
   * Only master can clear selection.
   */
  clearSelection(paneId: number): void {
    if (!this.isMaster) return;
    this.send({ type: "clear_selection", paneId });
  }

  /**
   * Apply a delta update to the local cache and notify as snapshot
   */
  private applyDelta(delta: BinaryDelta, paneState: PaneState): void {
    const paneId = delta.paneId;
    deltaLog.log(`Pane ${paneId}: Applying gen ${delta.fromGen} -> ${delta.gen}, ${delta.dirtyRows.length} dirty rows`);

    paneState.deltaCount++;
    paneState.cols = delta.cols;
    paneState.rows = delta.rows;

    type PendingRow = {
      cells: Cell[];
      graphemes: GraphemeTable | null;
      hyperlinks: HyperlinkTable | null;
    };

    const now = Date.now();
    const pendingRows = new Map<bigint, PendingRow>();

    // Canonicalize payload-local style IDs by style bytes using staged maps.
    const payloadStyles = decodeStyleTableFromBytes(delta.styles);
    const styles: StyleTable = paneState.lastStyles ? new Map(paneState.lastStyles) : new Map();
    const styleIdentity = cloneStyleIdentityState(paneState.styleIdentity);
    const payloadToCanonical = canonicalizePayloadStyles(payloadStyles, styles, styleIdentity);

    // Stage dirty row decode without mutating pane caches until validation passes.
    for (const row of delta.dirtyRows) {
      const rowId = BigInt(row.id);
      const rowCells = decodeCellsFromBytes(row.cells);
      const remapMisses = remapCellsToCanonicalStyles(rowCells, payloadToCanonical);
      if (remapMisses > 0) {
        deltaLog.warn(`Pane ${paneId}: row ${rowId} had ${remapMisses} unmapped styles, requesting resync`);
        this.requestResync(paneId, "style_miss");
        return;
      }

      pendingRows.set(rowId, {
        cells: rowCells,
        graphemes: row.graphemes ? decodeGraphemes(row.graphemes) : null,
        hyperlinks: row.hyperlinks ? decodeHyperlinks(row.hyperlinks) : null,
      });
    }

    // Decode row IDs from delta (tells us which rows are in viewport)
    if (!delta.rowIds || delta.rowIds.length === 0) {
      deltaLog.error("Delta missing rowIds!", delta);
      this.requestResync(paneId, "corruption");
      return;
    }
    const rowIds = decodeRowIds(delta.rowIds);
    if (rowIds.length !== delta.rows) {
      deltaLog.error(`Delta rowIds length mismatch: got ${rowIds.length}, expected ${delta.rows}`);
      this.requestResync(paneId, "corruption");
      return;
    }
    // Check which rowIds are in cache (excluding explicit invalid-row sentinels).
    // Rows staged in this delta are treated as cache hits.
    const notInCache = rowIds.filter(id => {
      if (id === INVALID_ROW_ID) {
        return false;
      }
      if (pendingRows.has(id)) {
        return false;
      }
      return !paneState.rowCache.has(id);
    });

    if (notInCache.length > 0) {
      deltaLog.warn(`Pane ${paneId}: ${notInCache.length} rows missing from cache, requesting resync`);
      this.requestResync(paneId, "cache_miss");
      return; // Don't emit corrupted snapshot
    }

    // Build cells array, grapheme table, and hyperlink table from cache for current viewport.
    // This requires knowing which row IDs are in the viewport
    // INVALID_ROW_ID rows are rendered as empty rows without cache lookup.
    const cells: Cell[] = [];
    const graphemes: GraphemeTable = new Map();
    const hyperlinks: HyperlinkTable = new Map();
    const viewportTouched = new Set<bigint>();
    let fromCache = 0;
    let fromDelta = 0;
    let filled = 0;
    let cacheCorrupt = false;
    for (let y = 0; y < delta.rows; y++) {
      const rowId = rowIds[y];
      if (rowId !== undefined && rowId !== INVALID_ROW_ID) {
        viewportTouched.add(rowId);

        const pending = pendingRows.get(rowId);
        const cached = pending ? null : paneState.rowCache.get(rowId);
        const rowCells = pending?.cells ?? cached?.cells;
        if (rowCells) {
          if (rowCells.length !== delta.cols) {
            deltaLog.warn(`Row ${y} (id=${rowId}) has ${rowCells.length} cells, expected ${delta.cols}`);
            cacheCorrupt = true;
            break;
          }
          cells.push(...rowCells);

          const rowStart = y * delta.cols;

          // Convert row-relative grapheme indices to global cell indices
          const rowGraphemes = pending?.graphemes ?? paneState.rowGraphemes.get(rowId);
          if (rowGraphemes) {
            for (const [colIndex, cps] of rowGraphemes) {
              graphemes.set(rowStart + colIndex, cps);
            }
          }

          // Convert row-relative hyperlink indices to global cell indices
          const rowHyperlinks = pending?.hyperlinks ?? paneState.rowHyperlinks.get(rowId);
          if (rowHyperlinks) {
            for (const [colIndex, url] of rowHyperlinks) {
              hyperlinks.set(rowStart + colIndex, url);
            }
          }

          if (pending) {
            fromDelta++;
          } else {
            fromCache++;
          }
          continue;
        }
      }
      // Fill with empty cells if row not in cache
      filled++;
      for (let x = 0; x < delta.cols; x++) {
        cells.push({
          content: { tag: 0, codepoint: 32 }, // space
          styleId: 0,
          wide: 0,
          protected: false,
          hyperlink: false,
        });
      }
    }
    if (cacheCorrupt) {
      this.requestResync(paneId, "corruption");
      return; // Don't emit corrupted snapshot
    }
    deltaLog.log(`Pane ${paneId}: Built ${fromCache} cached + ${fromDelta} dirty + ${filled} empty rows, ${graphemes.size} graphemes`);

    // Check if any cells reference styles we don't have
    const missingStyles = new Set<number>();
    for (const cell of cells) {
      if (cell.styleId !== 0 && !styles.has(cell.styleId)) {
        missingStyles.add(cell.styleId);
      }
    }
    if (missingStyles.size > 0) {
      deltaLog.warn(`Pane ${paneId}: ${missingStyles.size} styles missing, requesting resync`);
      this.requestResync(paneId, "style_miss");
      return; // Don't emit corrupted snapshot
    }

    // Validation passed. Commit staged dirty rows and style identity state.
    for (const [rowId, pending] of pendingRows) {
      paneState.rowCache.set(rowId, { cells: pending.cells, lastAccess: now });

      if (pending.graphemes && pending.graphemes.size > 0) {
        paneState.rowGraphemes.set(rowId, pending.graphemes);
      } else {
        paneState.rowGraphemes.delete(rowId);
      }

      if (pending.hyperlinks && pending.hyperlinks.size > 0) {
        paneState.rowHyperlinks.set(rowId, pending.hyperlinks);
      } else {
        paneState.rowHyperlinks.delete(rowId);
      }

      if (paneState.minRowId === null || rowId < paneState.minRowId) {
        paneState.minRowId = rowId;
      }
    }

    for (const rowId of viewportTouched) {
      if (pendingRows.has(rowId)) continue;
      const cached = paneState.rowCache.get(rowId);
      if (cached) {
        cached.lastAccess = now;
      }
    }

    paneState.styleIdentity = styleIdentity;
    paneState.lastStyles = styles;
    paneState.lastRowIds = rowIds;

    // Update generation only after validation to avoid desync on resync request
    paneState.generation = delta.gen;

    // Update last graphemes and hyperlinks for future merging
    paneState.lastGraphemes = graphemes;
    paneState.lastHyperlinks = hyperlinks;

    // Build merged snapshot
    const snapshot: TerminalSnapshot = {
      paneId,
      gen: delta.gen,
      cols: delta.cols,
      rows: delta.rows,
      cursor: {
        x: delta.cursor.x,
        y: delta.cursor.y,
        visible: delta.cursor.visible,
        style: delta.cursor.style as "block" | "underline" | "bar",
        blink: delta.cursor.blink ?? true, // Default to true (blinking) if not sent
      },
      altScreen: delta.altScreen,
      scrollback: {
        totalRows: delta.vp.totalRows,
        viewportTop: delta.vp.viewportTop,
      },
      cells,
      styles,
      rowIds,
      graphemes,
      hyperlinks,
      selection: delta.selection,
    };
    this.maybeFollowViewportTail(paneId, paneState, snapshot.scrollback, delta.rows);

    // Notify via onSnapshot (unified handler)
    this.emit("snapshot", snapshot);

    // Notify delta listeners with change info
    this.emit("delta", {
      paneId,
      gen: delta.gen,
      cols: delta.cols,
      rows: delta.rows,
      scrollback: {
        totalRows: delta.vp.totalRows,
        viewportTop: delta.vp.viewportTop,
      },
      changedRowIds: delta.dirtyRows.map(r => BigInt(r.id)),
    });

    // Extract title from delta if present
    const deltaTitle = (delta as any).title;
    if (deltaTitle && typeof deltaTitle === 'string') {
      deltaLog.log(`Pane ${paneId} title:`, deltaTitle);
      this.emit("title", paneId, deltaTitle);
    }

    // LRU-style cache pruning to prevent unbounded growth
    // Evict oldest accessed rows first, but never evict current viewport rows
    const MAX_CACHED_ROWS = 500;
    if (paneState.rowCache.size > MAX_CACHED_ROWS) {
      const viewportRowIdSet = new Set(rowIds);

      // Score each cached row by age (older = higher score = evict first)
      const scored: Array<[bigint, number]> = [];
      for (const [rowId, cached] of paneState.rowCache) {
        if (viewportRowIdSet.has(rowId)) continue; // Never evict viewport rows
        scored.push([rowId, now - cached.lastAccess]);
      }

      // Sort by score descending (oldest access first)
      scored.sort((a, b) => b[1] - a[1]);

      // Evict oldest until under limit
      const toEvict = paneState.rowCache.size - MAX_CACHED_ROWS;
      for (let i = 0; i < toEvict && i < scored.length; i++) {
        const [rowId] = scored[i]!;
        paneState.rowCache.delete(rowId);
        paneState.rowGraphemes.delete(rowId);
        paneState.rowHyperlinks.delete(rowId);
      }

      // Recalculate minRowId after pruning (we may have evicted the minimum)
      let newMinRowId: bigint | null = null;
      for (const rowId of paneState.rowCache.keys()) {
        if (newMinRowId === null || rowId < newMinRowId) {
          newMinRowId = rowId;
        }
      }
      paneState.minRowId = newMinRowId;

      deltaLog.log(`Pane ${paneId}: LRU pruned cache to ${paneState.rowCache.size} rows (evicted ${Math.min(toEvict, scored.length)} oldest, minRowId=${newMinRowId})`);
    }

    // Prune unused styles to prevent unbounded growth.
    // IMPORTANT: usage must be computed from the full row cache, not just viewport
    // cells, otherwise we can drop styles still referenced by cached scrollback rows.
    const MAX_CACHED_STYLES = 256;
    if (paneState.lastStyles && paneState.lastStyles.size > MAX_CACHED_STYLES) {
      const usedStyleIds = new Set<number>();
      for (const cached of paneState.rowCache.values()) {
        for (const cell of cached.cells) {
          if (cell.styleId !== 0) {
            usedStyleIds.add(cell.styleId);
          }
        }
      }
      // Remove styles not used by any cached row.
      pruneUnusedStyles(paneState.lastStyles, paneState.styleIdentity, usedStyleIds);
      deltaLog.log(`Pane ${paneId}: Pruned styles to ${paneState.lastStyles.size}`);
    }
  }

  /**
   * Extract current theme info for the server.
   * Returns theme name (for server-side lookup) plus fallback colors (for custom themes).
   *
   * The server uses themeName to look up full theme colors from its embedded database.
   * If the theme isn't found, it falls back to themeFg/themeBg CSS values.
   * This eliminates the race condition where CSS wasn't loaded when colors were queried.
   */
  private getThemeInfo(): { themeName?: string; themeFg?: string; themeBg?: string } {
    // Get theme name from config (primary source for server lookup)
    const themeName = getConfig("theme");

    // Also send CSS colors as fallback (for custom themes or if name lookup fails)
    try {
      const appElement = document.querySelector(".app");
      if (!appElement) {
        return { themeName };
      }
      const style = getComputedStyle(appElement);
      const fg = style.getPropertyValue("--term-fg").trim();
      const bg = style.getPropertyValue("--term-bg").trim();
      return {
        themeName,
        themeFg: fg || undefined,
        themeBg: bg || undefined,
      };
    } catch {
      // Fallback if CSS variables not available
      return { themeName };
    }
  }

  private send(msg: ClientMessage): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      const payload = JSON.stringify(msg);
      if (this._sendQueue.length > 0 || this.ws.bufferedAmount > TerminalConnection.MAX_BUFFERED_BYTES) {
        this.enqueueSend(payload);
        return;
      }
      this.ws.send(payload);
      if (this.ws.bufferedAmount > TerminalConnection.MAX_BUFFERED_BYTES) {
        this.scheduleFlush();
      }
    }
  }

  private enqueueSend(payload: string): void {
    if (this._sendQueueBytes + payload.length > TerminalConnection.MAX_QUEUE_BYTES) {
      connLog.warn("Send queue overflow, disconnecting");
      this.ws?.close();
      return;
    }
    this._sendQueue.push(payload);
    this._sendQueueBytes += payload.length;
    this.scheduleFlush();
  }

  private flushSendQueue(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return;
    }
    while (this._sendQueue.length > 0 && this.ws.bufferedAmount < TerminalConnection.MAX_BUFFERED_BYTES) {
      const payload = this._sendQueue.shift()!;
      this._sendQueueBytes -= payload.length;
      this.ws.send(payload);
    }
    if (this._sendQueue.length > 0) {
      this.scheduleFlush();
    }
  }

  private scheduleFlush(): void {
    if (this._flushTimer !== null) {
      return;
    }
    this._flushTimer = window.setTimeout(() => {
      this._flushTimer = null;
      this.flushSendQueue();
    }, TerminalConnection.FLUSH_INTERVAL_MS);
  }

  private clearSendQueue(): void {
    if (this._flushTimer !== null) {
      window.clearTimeout(this._flushTimer);
      this._flushTimer = null;
    }
    this._sendQueue.length = 0;
    this._sendQueueBytes = 0;
  }

  get isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }
}

/**
 * Convert cells to lines of text (for simple rendering).
 * @param cells - Array of cells
 * @param cols - Number of columns
 * @param rows - Number of rows
 * @param graphemes - Optional grapheme table for multi-codepoint characters
 */
export function cellsToLines(
  cells: Cell[],
  cols: number,
  rows: number,
  graphemes?: GraphemeTable
): string[] {
  const lines: string[] = [];
  for (let y = 0; y < rows; y++) {
    let line = "";
    for (let x = 0; x < cols; x++) {
      const idx = y * cols + x;
      const cell = cells[idx];
      line += cell ? cellToChar(cell, graphemes, idx) : " ";
    }
    lines.push(line.trimEnd());
  }
  return lines;
}
