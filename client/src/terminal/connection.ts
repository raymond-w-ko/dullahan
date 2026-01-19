import { debug } from "../debug";
import { get as getConfig } from "../config";
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
import { ColorTag, decodeStyleTableFromBytes } from "../../../protocol/schema/style";
import { calculateTerminalSize } from "./dimensions";
import type { StyleTable, Style, Color } from "../../../protocol/schema/style";
import type { KeyMessage } from "./keyboard";
import type { TextMessage } from "./ime";
import type { MouseMessage } from "./mouse";
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

/** Per-pane state for delta sync tracking */
interface PaneState {
  generation: number;
  minRowId: bigint;
  rowCache: Map<bigint, Cell[]>;
  rowGraphemes: Map<bigint, GraphemeTable>; // Graphemes per row (row-relative indices)
  rowHyperlinks: Map<bigint, HyperlinkTable>; // Hyperlinks per row (row-relative indices)
  cols: number;
  rows: number;
  lastStyles: StyleTable | null;
  lastRowIds: bigint[] | null;
  lastGraphemes: GraphemeTable | null; // Last snapshot's graphemes (global indices)
  lastHyperlinks: HyperlinkTable | null; // Last snapshot's hyperlinks (global indices)
  deltaCount: number;
  resyncCount: number;
}

/** Storage key for client ID */
const CLIENT_ID_KEY = "dullahan_client_id";

/** Get or generate client ID (persisted in sessionStorage) */
function getClientId(): string {
  let clientId = sessionStorage.getItem(CLIENT_ID_KEY);
  if (!clientId) {
    clientId = uuidv4();
    sessionStorage.setItem(CLIENT_ID_KEY, clientId);
    debug.log("Generated new client ID:", clientId);
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

  // Master/slave state - tracks if this client is the master
  private _masterId: string | null = null;

  // Layout state - current window/pane mappings
  private _layout: LayoutUpdate | null = null;

  // Per-pane delta sync state
  private _panes: Map<number, PaneState> = new Map();

  // Pending resize tracking - resizes are queued and sent when connected
  private _pendingResizes: Map<number, { cols: number; rows: number }> = new Map();
  private _lastSentResizes: Map<number, { cols: number; rows: number }> = new Map();
  private _resizeDebounceTimer: number | null = null;
  private static readonly RESIZE_DEBOUNCE_MS = 333;

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

  /** Get or create pane state */
  private getPaneState(paneId: number): PaneState {
    let state = this._panes.get(paneId);
    if (!state) {
      state = {
        generation: 0,
        minRowId: 0n,
        rowCache: new Map(),
        rowGraphemes: new Map(),
        rowHyperlinks: new Map(),
        cols: 80,
        rows: 24,
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

  /** Total delta count across all panes */
  get totalDeltaCount(): number {
    let total = 0;
    for (const pane of this._panes.values()) {
      total += pane.deltaCount;
    }
    return total;
  }

  /** Total resync count across all panes */
  get totalResyncCount(): number {
    let total = 0;
    for (const pane of this._panes.values()) {
      total += pane.resyncCount;
    }
    return total;
  }

  /** Get cached row by ID for a pane, or undefined if not cached */
  getCachedRow(paneId: number, rowId: bigint): Cell[] | undefined {
    return this._panes.get(paneId)?.rowCache.get(rowId);
  }

  connect(): void {
    if (this.ws) {
      this.ws.close();
    }

    debug.log(`Connecting to ${this.url}...`);
    this.ws = new WebSocket(this.url);

    this.ws.onopen = () => {
      debug.log("WebSocket connected");
      // Reset reconnect backoff on successful connection
      this.reconnectAttempts = 0;
      // Send hello message to identify this client with theme colors
      const themeColors = this.getThemeColors();
      this.send({
        type: "hello",
        clientId: this._clientId,
        ...themeColors,
      });
      debug.log("Sent hello with client ID:", this._clientId, "theme:", themeColors);
      // Flush any pending resizes now that we're connected
      this.flushPendingResizes();
      this.emit("connect");
    };

    this.ws.onclose = () => {
      debug.log("WebSocket disconnected");
      this.emit("disconnect");
      this.scheduleReconnect();
    };

    this.ws.onerror = (event) => {
      debug.error("WebSocket error:", event);
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
            debug.log(`Received ${(msg as any).type} message, keys:`, Object.keys(msg));
          }
          this.handleBinaryMessage(msg);
        } else {
          // Legacy JSON message (shouldn't happen with new server)
          debug.warn("Received text message, expected binary");
        }
      } catch (e) {
        debug.error("Failed to parse message:", e);
      }
    };
  }

  private handleBinaryMessage(msg: ServerMessage): void {
    switch (msg.type) {
      case "snapshot": {
        const paneId = msg.paneId;
        const paneState = this.getPaneState(paneId);

        debug.log(`Received snapshot for pane ${paneId}:`, msg.cols, "x", msg.rows,
          "scrollback:", msg.scrollback.totalRows, "top:", msg.scrollback.viewportTop);

        // Decode cells, styles, row IDs, graphemes, and hyperlinks from raw bytes
        const cells = decodeCellsFromBytes(msg.cells);
        const styles = decodeStyleTableFromBytes(msg.styles);
        const rowIds = decodeRowIds(msg.rowIds);
        const graphemes = msg.graphemes ? decodeGraphemes(msg.graphemes) : new Map();
        const hyperlinks = msg.hyperlinks ? decodeHyperlinks(msg.hyperlinks) : new Map();
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

        // Rebuild row cache, graphemes, and hyperlinks from snapshot
        // NOTE: rowId=0 IS valid (page serial 0, row index 0)
        // Only undefined means the row wasn't sent
        paneState.rowCache.clear();
        paneState.rowGraphemes.clear();
        paneState.rowHyperlinks.clear();
        let minSeen = -1n;  // Use -1n as "not set" since row IDs are unsigned
        for (let y = 0; y < msg.rows; y++) {
          const rowId = rowIds[y];
          if (rowId !== undefined) {
            const rowCells = cells.slice(y * msg.cols, (y + 1) * msg.cols);
            paneState.rowCache.set(rowId, rowCells);
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
        if (minSeen >= 0n) {
          paneState.minRowId = minSeen;
        }

        // Save for delta merging
        paneState.lastStyles = styles;
        paneState.lastRowIds = rowIds;
        paneState.lastGraphemes = graphemes;
        paneState.lastHyperlinks = hyperlinks;

        debug.log(`Pane ${paneId}: stored ${paneState.rowCache.size} rows in cache, ${graphemes.size} graphemes, ${hyperlinks.size} hyperlinks, rowIds:`, rowIds.map(String));

        this.emit("snapshot", snapshot);

        // Extract title from snapshot if present
        const snapshotTitle = (msg as any).title;
        if (snapshotTitle && typeof snapshotTitle === 'string') {
          debug.log("Snapshot includes title for pane", paneId, ":", snapshotTitle);
          this.emit("title", paneId, snapshotTitle);
        }
        break;
      }
      case "delta": {
        const paneId = msg.paneId;
        const paneState = this.getPaneState(paneId);

        debug.log(`Raw delta for pane ${paneId}:`, {
          type: msg.type,
          fromGen: msg.fromGen,
          gen: msg.gen,
          hasRowIds: 'rowIds' in msg,
          rowIdsType: typeof (msg as any).rowIds,
          rowIdsConstructor: (msg as any).rowIds?.constructor?.name,
        });

        // Check if we can apply this delta
        // Client must be at fromGen to apply delta that brings us to gen
        if (paneState.generation === msg.fromGen) {
          this.applyDelta(msg, paneState);
        } else if (paneState.generation < msg.fromGen) {
          // We're behind - request full snapshot
          debug.log(`Pane ${paneId}: Delta fromGen ${msg.fromGen} > our gen ${paneState.generation}, requesting snapshot`);
          paneState.resyncCount++;
          this.sendSync(paneId, paneState.generation, Number(paneState.minRowId));
        } else {
          // We're ahead of fromGen - this delta is stale, ignore it
          // But if we're behind the target gen, request sync
          if (paneState.generation < msg.gen) {
            debug.log(`Pane ${paneId}: Stale delta (fromGen ${msg.fromGen} < our gen ${paneState.generation}), but behind target ${msg.gen}, requesting sync`);
            paneState.resyncCount++;
            this.sendSync(paneId, paneState.generation, Number(paneState.minRowId));
          } else {
            debug.log(`Pane ${paneId}: Stale delta ignored (fromGen ${msg.fromGen}, our gen ${paneState.generation})`);
          }
        }
        break;
      }
      case "output":
        this.emit("output", msg.data);
        break;
      case "title":
        debug.log("Received title for pane", msg.paneId, ":", msg.title);
        this.emit("title", msg.paneId, msg.title);
        break;
      case "bell":
        debug.log("Received bell");
        this.emit("bell");
        break;
      case "toast":
        debug.log("Received toast:", msg.paneId, msg.title, msg.message);
        this.emit("toast", msg.paneId, msg.title, msg.message);
        break;
      case "progress":
        debug.log("Received progress:", msg.paneId, msg.state, msg.value);
        this.emit("progress", msg.paneId, msg.state, msg.value);
        break;
      case "shell_integration": {
        // OSC 133 shell integration event
        // Always log to console for debugging (TODO: remove after verification)
        const exitStr = msg.exitCode !== undefined ? ` exit=${msg.exitCode}` : "";
        console.log(
          `%c[shell]%c pane=${msg.paneId} event=${msg.event}${exitStr}`,
          "color: #00aa00; font-weight: bold",
          "color: inherit"
        );
        this.emit("shellIntegration", msg.paneId, msg.event, msg.exitCode);
        break;
      }
      case "focus":
        debug.log("Received focus:", msg.paneId);
        this.emit("focus", msg.paneId);
        break;
      case "master_changed": {
        this._masterId = msg.masterId;
        const isMaster = this._masterId !== null && this._masterId === this._clientId;
        debug.log("Master changed:", msg.masterId, "isMaster:", isMaster);
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
        debug.log("Layout received:", msg.windows.length, "windows,", msg.templates?.length ?? 0, "templates, active:", msg.activeWindowId);
        this.emit("layout", this._layout);
        break;
      }
      case "pong":
        // Ignore pong
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
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
    }
    // Exponential backoff: 250ms, 500ms, 1s, 2s, 4s (cap at 5s)
    const baseDelay = 250;
    const delay = Math.min(baseDelay * Math.pow(2, this.reconnectAttempts), 5000);
    this.reconnectAttempts++;
    debug.log(`Scheduling reconnect in ${delay}ms (attempt ${this.reconnectAttempts})`);
    this.reconnectTimer = window.setTimeout(() => {
      debug.log("Attempting to reconnect...");
      this.connect();
    }, delay);
  }

  disconnect(): void {
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
  sendResize(paneId: number, cols: number, rows: number): void {
    if (!this.isMaster) return;
    this.send({ type: "resize", paneId, cols, rows });
  }

  /**
   * Calculate pane dimensions from a container element.
   * Returns { cols, rows } or { cols: -1, rows: -1 } if not ready (no measurement possible).
   * This is synchronous and does not send anything.
   *
   * Uses a persistent measurement element (.terminal-measure) that stays in the DOM
   * for efficiency and debuggability in Chrome DevTools.
   */
  calculatePaneSize(container: HTMLElement): { cols: number; rows: number } {
    const { cols, rows } = calculateTerminalSize(container);
    return { cols, rows };
  }

  /**
   * Mark that a pane needs to be resized.
   * Does not send immediately - call flushPendingResizes() or wait for connection.
   * Skips if dimensions match last sent values.
   */
  setPaneSize(paneId: number, cols: number, rows: number): void {
    // Skip if not ready
    if (cols < 0 || rows < 0) {
      return;
    }

    // Skip if same as last sent
    const lastSent = this._lastSentResizes.get(paneId);
    if (lastSent && lastSent.cols === cols && lastSent.rows === rows) {
      return;
    }

    // Queue the resize
    this._pendingResizes.set(paneId, { cols, rows });
    debug.log(`Queued resize for pane ${paneId}: ${cols}x${rows}`);

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
      debug.log(`Sending resize for pane ${paneId}: ${size.cols}x${size.rows}`);
      this.send({ type: "resize", paneId, cols: size.cols, rows: size.rows });
      this._lastSentResizes.set(paneId, size);
    }
    this._pendingResizes.clear();
  }

  /**
   * Scroll the terminal viewport by delta rows.
   * Negative values scroll up (toward history), positive scroll down.
   * Only master can scroll.
   */
  sendScroll(paneId: number, delta: number): void {
    if (!this.isMaster) return;
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
    debug.log("Requesting master status");
    this.send({ type: "request_master" });
  }

  /**
   * Create a new window with default panes.
   * Only the master client can create windows. Non-masters will have
   * their requests silently ignored by the server.
   * @param templateId Optional layout template ID (e.g., "2-col", "2x2", "single")
   */
  createWindow(templateId?: string): void {
    debug.log("Requesting new window creation", templateId ? `with template: ${templateId}` : "");
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
    debug.log("Requesting window close:", windowId);
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
    debug.log("Requesting pane close:", paneId);
    this.send({ type: "close_pane", paneId });
  }

  sendPing(): void {
    this.send({ type: "ping" });
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
   * Request sync for all panes
   */
  requestSyncAll(): void {
    for (const [paneId, state] of this._panes) {
      this.sendSync(paneId, state.generation, Number(state.minRowId));
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
    debug.log(`Pane ${paneId}: Applying delta: gen ${delta.fromGen} -> ${delta.gen}, ${delta.dirtyRows.length} dirty rows`);
    debug.log(`Delta details:`, {
      cols: delta.cols,
      rows: delta.rows,
      cursor: delta.cursor,
      altScreen: delta.altScreen,
      vp: delta.vp,
      rowIdsLen: delta.rowIds?.length,
      stylesLen: delta.styles?.length,
      dirtyRowIds: delta.dirtyRows.map(r => r.id),
    });

    paneState.deltaCount++;
    paneState.cols = delta.cols;
    paneState.rows = delta.rows;

    // Apply each dirty row to cache (including graphemes)
    for (const row of delta.dirtyRows) {
      const rowId = BigInt(row.id);
      const cells = decodeCellsFromBytes(row.cells);

      paneState.rowCache.set(rowId, cells);

      // Decode and cache graphemes for this row (row-relative indices)
      if (row.graphemes) {
        const rowGraphemes = decodeGraphemes(row.graphemes);
        if (rowGraphemes.size > 0) {
          paneState.rowGraphemes.set(rowId, rowGraphemes);
        } else {
          paneState.rowGraphemes.delete(rowId);
        }
      } else {
        // No graphemes in this row, clear any cached graphemes
        paneState.rowGraphemes.delete(rowId);
      }

      // Decode and cache hyperlinks for this row (row-relative indices)
      if (row.hyperlinks) {
        const rowHyperlinks = decodeHyperlinks(row.hyperlinks);
        if (rowHyperlinks.size > 0) {
          paneState.rowHyperlinks.set(rowId, rowHyperlinks);
        } else {
          paneState.rowHyperlinks.delete(rowId);
        }
      } else {
        // No hyperlinks in this row, clear any cached hyperlinks
        paneState.rowHyperlinks.delete(rowId);
      }

      // Update min row ID tracking
      if (paneState.minRowId === 0n || rowId < paneState.minRowId) {
        paneState.minRowId = rowId;
      }
    }

    // Update generation
    paneState.generation = delta.gen;

    // Decode styles from delta
    const styles = decodeStyleTableFromBytes(delta.styles);

    // Merge with existing styles from last snapshot
    // Delta styles take precedence (they're the current ones)
    if (paneState.lastStyles) {
      for (const [id, style] of paneState.lastStyles) {
        if (!styles.has(id)) {
          styles.set(id, style);
        }
      }
    }
    paneState.lastStyles = styles;

    // Decode row IDs from delta (tells us which rows are in viewport)
    if (!delta.rowIds || delta.rowIds.length === 0) {
      debug.error("Delta missing rowIds!", delta);
      // Fall back to last known rowIds
    }
    const rowIds = delta.rowIds ? decodeRowIds(delta.rowIds) : (paneState.lastRowIds ?? []);
    paneState.lastRowIds = rowIds;
    debug.log(`Pane ${paneId}: Decoded ${rowIds.length} rowIds:`, rowIds.map(String));
    debug.log(`Pane ${paneId}: Row cache size: ${paneState.rowCache.size}, keys:`, [...paneState.rowCache.keys()].map(String));

    // Check which rowIds are in cache
    // NOTE: rowId=0 IS valid (page serial 0, row index 0)
    const inCache = rowIds.filter(id => paneState.rowCache.has(id));
    const notInCache = rowIds.filter(id => !paneState.rowCache.has(id));
    debug.log(`Pane ${paneId}: RowIds in cache: ${inCache.length}, not in cache: ${notInCache.length}`);
    if (notInCache.length > 0) {
      debug.log(`Pane ${paneId}: Missing rowIds:`, notInCache.map(String));
      debug.log(`Pane ${paneId}: Cache has:`, [...paneState.rowCache.keys()].map(String));
    }

    // Build cells array, grapheme table, and hyperlink table from cache for current viewport
    // This requires knowing which row IDs are in the viewport
    // NOTE: rowId=0 IS valid, only undefined means "no row"
    const cells: Cell[] = [];
    const graphemes: GraphemeTable = new Map();
    const hyperlinks: HyperlinkTable = new Map();
    let fromCache = 0;
    let filled = 0;
    for (let y = 0; y < delta.rows; y++) {
      const rowId = rowIds[y];
      if (rowId !== undefined) {
        const rowCells = paneState.rowCache.get(rowId);
        if (rowCells) {
          if (rowCells.length !== delta.cols) {
            debug.warn(`Row ${y} (id=${rowId}) has ${rowCells.length} cells, expected ${delta.cols}`);
          }
          cells.push(...rowCells);

          const rowStart = y * delta.cols;

          // Convert row-relative grapheme indices to global cell indices
          const rowGraphemes = paneState.rowGraphemes.get(rowId);
          if (rowGraphemes) {
            for (const [colIndex, cps] of rowGraphemes) {
              graphemes.set(rowStart + colIndex, cps);
            }
          }

          // Convert row-relative hyperlink indices to global cell indices
          const rowHyperlinks = paneState.rowHyperlinks.get(rowId);
          if (rowHyperlinks) {
            for (const [colIndex, url] of rowHyperlinks) {
              hyperlinks.set(rowStart + colIndex, url);
            }
          }

          fromCache++;
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
    debug.log(`Pane ${paneId}: Built cells: ${fromCache} rows from cache, ${filled} rows filled empty, ${graphemes.size} graphemes, ${hyperlinks.size} hyperlinks`);

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
      debug.log("Delta includes title for pane", paneId, ":", deltaTitle);
      this.emit("title", paneId, deltaTitle);
    }
  }

  /**
   * Extract current theme colors from CSS variables.
   * Returns fg/bg colors that can be sent to the server for OSC 10/11 queries.
   * Queries .app element since that's where data-theme sets the CSS variables.
   */
  private getThemeColors(): { themeFg?: string; themeBg?: string } {
    try {
      // Get computed style from .app element which has data-theme attribute
      const appElement = document.querySelector(".app");
      if (!appElement) {
        return {};
      }
      const style = getComputedStyle(appElement);
      const fg = style.getPropertyValue("--term-fg").trim();
      const bg = style.getPropertyValue("--term-bg").trim();
      return {
        themeFg: fg || undefined,
        themeBg: bg || undefined,
      };
    } catch {
      // Fallback if CSS variables not available
      return {};
    }
  }

  private send(msg: ClientMessage): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
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
