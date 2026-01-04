import { debug } from "../debug";
// WebSocket connection to dullahan server
// Uses binary msgpack for efficient data transmission
// Messages are compressed with Snappy

import { decode } from "@msgpack/msgpack";
import SnappyJS from "snappyjs";
import { cellToChar, ContentTag, Wide } from "../../../protocol/schema/cell";
import type { Cell, CellContent, WideValue } from "../../../protocol/schema/cell";
import { ColorTag, Underline } from "../../../protocol/schema/style";
import type { StyleTable, Style, Color, UnderlineValue } from "../../../protocol/schema/style";
import type { KeyMessage } from "./keyboard";
import type { TextMessage } from "./ime";

export interface ScrollbackInfo {
  totalRows: number;    // Total rows including scrollback
  viewportTop: number;  // Current viewport offset from top
}

export interface TerminalSnapshot {
  gen: number; // Generation counter for delta sync
  cols: number;
  rows: number;
  cursor: {
    x: number;
    y: number;
    visible: boolean;
    style: "block" | "underline" | "bar";
  };
  altScreen: boolean;
  scrollback: ScrollbackInfo;
  cells: Cell[]; // Decoded cell data
  styles: StyleTable; // Decoded style table
  rowIds: bigint[]; // Stable row IDs for delta sync (one per row)
}

/** Binary msgpack snapshot from server */
interface BinarySnapshot {
  type: "snapshot";
  gen: number;         // Generation counter for delta sync
  cols: number;
  rows: number;
  cursor: {
    x: number;
    y: number;
    visible: boolean;
    style: string;
  };
  altScreen: boolean;
  scrollback: {
    totalRows: number;
    viewportTop: number;
  };
  cells: Uint8Array;   // Raw cell bytes
  styles: Uint8Array;  // Raw style bytes
  rowIds: Uint8Array;  // Packed u64 row IDs (little-endian)
}

/** Binary msgpack delta update from server */
interface BinaryDelta {
  type: "delta";
  gen: number;         // New generation after applying
  cols: number;
  rows: number;
  cursor: {
    x: number;
    y: number;
    visible: boolean;
    style: string;
  };
  altScreen: boolean;
  vp: {
    totalRows: number;
    viewportTop: number;
  };
  dirtyRows: Array<{
    id: number;        // Row ID (as number, fits in 53 bits)
    cells: Uint8Array; // Raw cell bytes for this row
  }>;
  rowIds: Uint8Array;  // Packed u64 row IDs for viewport (little-endian)
  styles: Uint8Array;  // Raw style bytes for dirty rows
}

/** Title update message from server */
interface TitleMessage {
  type: "title";
  title: string;
}

/** Bell notification from server (BEL 0x07 triggered) */
interface BellMessage {
  type: "bell";
}

export type BinaryServerMessage =
  | BinarySnapshot
  | BinaryDelta
  | TitleMessage
  | BellMessage
  | { type: "output"; data: string }
  | { type: "pong" };

export type ClientMessage =
  | KeyMessage
  | TextMessage
  | { type: "resize"; cols: number; rows: number }
  | { type: "scroll"; delta: number }  // Scroll viewport by delta rows (negative = up)
  | { type: "ping" }
  | { type: "sync"; gen: number; minRowId: number };

/** Delta update event with applied changes */
export interface DeltaUpdate {
  gen: number;
  cols: number;
  rows: number;
  scrollback: ScrollbackInfo;
  changedRowIds: bigint[]; // Row IDs that were updated
}

export class TerminalConnection {
  private ws: WebSocket | null = null;
  private url: string;
  private reconnectTimer: number | null = null;

  // Delta sync state
  private _generation: number = 0;
  private _minRowId: bigint = 0n;
  private _rowCache: Map<bigint, Cell[]> = new Map();
  private _cols: number = 80;
  private _rows: number = 24;
  private _lastStyles: StyleTable | null = null;  // Cached styles for delta merging
  private _lastRowIds: bigint[] | null = null;    // Cached row IDs for delta merging

  // Stats for debugging
  private _deltaCount: number = 0;
  private _resyncCount: number = 0;

  public onSnapshot: ((snapshot: TerminalSnapshot) => void) | null = null;
  public onDelta: ((delta: DeltaUpdate) => void) | null = null;
  public onOutput: ((data: string) => void) | null = null;
  public onTitle: ((title: string) => void) | null = null;
  public onBell: (() => void) | null = null;
  public onConnect: (() => void) | null = null;
  public onDisconnect: (() => void) | null = null;
  public onError: ((error: string) => void) | null = null;

  constructor(url: string = "ws://localhost:7681") {
    this.url = url;
  }

  /** Current generation (for sync requests) */
  get generation(): number { return this._generation; }

  /** Oldest row ID in cache (for sync requests) */
  get minRowId(): bigint { return this._minRowId; }

  /** Debug stats: number of delta updates received */
  get deltaCount(): number { return this._deltaCount; }

  /** Debug stats: number of full resyncs */
  get resyncCount(): number { return this._resyncCount; }

  /** Get cached row by ID, or undefined if not cached */
  getCachedRow(rowId: bigint): Cell[] | undefined {
    return this._rowCache.get(rowId);
  }

  connect(): void {
    if (this.ws) {
      this.ws.close();
    }

    debug.log(`Connecting to ${this.url}...`);
    this.ws = new WebSocket(this.url);

    this.ws.onopen = () => {
      debug.log("WebSocket connected");
      this.onConnect?.();
    };

    this.ws.onclose = () => {
      debug.log("WebSocket disconnected");
      this.onDisconnect?.();
      this.scheduleReconnect();
    };

    this.ws.onerror = (event) => {
      console.error("WebSocket error:", event);
      this.onError?.("Connection error");
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
          const decompressed = isCompressed ? SnappyJS.uncompress(payload) : payload;
          const msg = decode(decompressed) as BinaryServerMessage;
          // Log raw message keys for debugging
          if (msg && typeof msg === 'object') {
            debug.log(`Received ${(msg as any).type} message, keys:`, Object.keys(msg));
          }
          this.handleBinaryMessage(msg);
        } else {
          // Legacy JSON message (shouldn't happen with new server)
          console.warn("Received text message, expected binary");
        }
      } catch (e) {
        console.error("Failed to parse message:", e);
      }
    };
  }

  private handleBinaryMessage(msg: BinaryServerMessage): void {
    switch (msg.type) {
      case "snapshot":
        debug.log("Received binary snapshot:", msg.cols, "x", msg.rows, 
          "scrollback:", msg.scrollback.totalRows, "top:", msg.scrollback.viewportTop);
        // Decode cells, styles, and row IDs from raw bytes
        const cells = this.decodeCellsFromBytes(msg.cells);
        const styles = this.decodeStyleTableFromBytes(msg.styles);
        const rowIds = this.decodeRowIdsFromBytes(msg.rowIds);
        const snapshot: TerminalSnapshot = {
          gen: msg.gen,
          cols: msg.cols,
          rows: msg.rows,
          cursor: {
            x: msg.cursor.x,
            y: msg.cursor.y,
            visible: msg.cursor.visible,
            style: msg.cursor.style as "block" | "underline" | "bar",
          },
          altScreen: msg.altScreen,
          scrollback: msg.scrollback,
          cells,
          styles,
          rowIds,
        };
        // Update internal state from snapshot
        this._generation = msg.gen;
        this._cols = msg.cols;
        this._rows = msg.rows;
        this._resyncCount++;

        // Rebuild row cache from snapshot
        // NOTE: rowId=0 IS valid (page serial 0, row index 0)
        // Only undefined means the row wasn't sent
        this._rowCache.clear();
        let minSeen = -1n;  // Use -1n as "not set" since row IDs are unsigned
        for (let y = 0; y < msg.rows; y++) {
          const rowId = rowIds[y];
          if (rowId !== undefined) {
            const rowCells = cells.slice(y * msg.cols, (y + 1) * msg.cols);
            this._rowCache.set(rowId, rowCells);
            // Track minimum row ID
            if (minSeen < 0n || rowId < minSeen) {
              minSeen = rowId;
            }
          }
        }
        if (minSeen >= 0n) {
          this._minRowId = minSeen;
        }

        // Save for delta merging
        this._lastStyles = styles;
        this._lastRowIds = rowIds;
        
        debug.log(`Snapshot stored ${this._rowCache.size} rows in cache, rowIds:`, rowIds.map(String));

        this.onSnapshot?.(snapshot);

        // Extract title from snapshot if present
        const snapshotTitle = (msg as any).title;
        if (snapshotTitle && typeof snapshotTitle === 'string') {
          debug.log("Snapshot includes title:", snapshotTitle);
          this.onTitle?.(snapshotTitle);
        }
        break;
      case "delta":
        debug.log("Raw delta message:", {
          type: msg.type,
          gen: msg.gen,
          hasRowIds: 'rowIds' in msg,
          rowIdsType: typeof (msg as any).rowIds,
          rowIdsConstructor: (msg as any).rowIds?.constructor?.name,
        });
        this.applyDelta(msg);
        break;
      case "output":
        this.onOutput?.(msg.data);
        break;
      case "title":
        debug.log("Received title:", msg.title);
        this.onTitle?.(msg.title);
        break;
      case "bell":
        debug.log("Received bell");
        this.onBell?.();
        break;
      case "pong":
        // Ignore pong
        break;
    }
  }

  /** Decode cells from raw bytes (8 bytes per cell) */
  private decodeCellsFromBytes(data: Uint8Array): Cell[] {
    const cellSize = 8;
    const count = Math.floor(data.length / cellSize);
    const cells: Cell[] = [];

    for (let i = 0; i < count; i++) {
      const offset = i * cellSize;
      
      // Read two u32 in little-endian
      const lo = (data[offset] ?? 0) | 
                 ((data[offset + 1] ?? 0) << 8) | 
                 ((data[offset + 2] ?? 0) << 16) | 
                 ((data[offset + 3] ?? 0) << 24);
      const hi = (data[offset + 4] ?? 0) | 
                 ((data[offset + 5] ?? 0) << 8) | 
                 ((data[offset + 6] ?? 0) << 16) | 
                 ((data[offset + 7] ?? 0) << 24);
      
      // Decode using the same bit layout as cell.ts
      const contentTag = (lo & 0x3) as 0 | 1 | 2 | 3;
      const contentBits = (lo >>> 2) & 0xffffff;
      const styleIdLo = (lo >>> 26) & 0x3f;
      const styleIdHi = hi & 0x3ff;
      const styleId = styleIdLo | (styleIdHi << 6);
      const wide = ((hi >>> 10) & 0x3) as WideValue;
      const isProtected = ((hi >>> 12) & 0x1) === 1;
      const isHyperlink = ((hi >>> 13) & 0x1) === 1;
      
      let content: CellContent;
      switch (contentTag) {
        case ContentTag.CODEPOINT:
          content = { tag: ContentTag.CODEPOINT, codepoint: contentBits & 0x1fffff };
          break;
        case ContentTag.CODEPOINT_GRAPHEME:
          content = { tag: ContentTag.CODEPOINT_GRAPHEME, codepoint: contentBits & 0x1fffff };
          break;
        case ContentTag.BG_COLOR_PALETTE:
          content = { tag: ContentTag.BG_COLOR_PALETTE, palette: contentBits & 0xff };
          break;
        case ContentTag.BG_COLOR_RGB:
          content = {
            tag: ContentTag.BG_COLOR_RGB,
            rgb: {
              r: contentBits & 0xff,
              g: (contentBits >>> 8) & 0xff,
              b: (contentBits >>> 16) & 0xff,
            },
          };
          break;
      }
      
      cells.push({
        content,
        styleId,
        wide,
        protected: isProtected,
        hyperlink: isHyperlink,
      });
    }

    return cells;
  }

  /** Decode a color from 4 bytes */
  private decodeColor(data: Uint8Array, offset: number): Color {
    const tag = data[offset] ?? 0;
    switch (tag) {
      case ColorTag.NONE:
        return { tag: ColorTag.NONE };
      case ColorTag.PALETTE:
        return { tag: ColorTag.PALETTE, index: data[offset + 1] ?? 0 };
      case ColorTag.RGB:
        return { 
          tag: ColorTag.RGB, 
          r: data[offset + 1] ?? 0, 
          g: data[offset + 2] ?? 0, 
          b: data[offset + 3] ?? 0 
        };
      default:
        return { tag: ColorTag.NONE };
    }
  }

  /** Decode row IDs from packed u64 bytes (little-endian) */
  private decodeRowIdsFromBytes(data: Uint8Array): bigint[] {
    if (!data || data.length === 0) {
      console.warn("decodeRowIdsFromBytes: empty or missing data");
      return [];
    }
    
    // Ensure we have a proper Uint8Array
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    
    const rowIds: bigint[] = [];
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    
    for (let i = 0; i < bytes.length; i += 8) {
      // Read u64 as two u32s in little-endian and combine
      const lo = view.getUint32(i, true);
      const hi = view.getUint32(i + 4, true);
      const rowId = BigInt(lo) | (BigInt(hi) << 32n);
      rowIds.push(rowId);
    }
    
    return rowIds;
  }

  /** Decode style table from raw bytes */
  private decodeStyleTableFromBytes(data: Uint8Array): StyleTable {
    const styles = new Map<number, Style>();
    
    if (data.length < 2) return styles;
    
    const count = (data[0] ?? 0) | ((data[1] ?? 0) << 8);
    let offset = 2;
    
    for (let i = 0; i < count && offset + 16 <= data.length; i++) {
      const styleId = (data[offset] ?? 0) | ((data[offset + 1] ?? 0) << 8);
      offset += 2;
      
      const fgColor = this.decodeColor(data, offset);
      const bgColor = this.decodeColor(data, offset + 4);
      const underlineColor = this.decodeColor(data, offset + 8);
      
      // Flags (2 bytes, little-endian)
      const flagsWord = (data[offset + 12] ?? 0) | ((data[offset + 13] ?? 0) << 8);
      const underlineRaw = (flagsWord >> 8) & 0x07;
      const underline: UnderlineValue = (underlineRaw <= 5 ? underlineRaw : Underline.NONE) as UnderlineValue;
      
      const flags = {
        bold: (flagsWord & 0x01) !== 0,
        italic: (flagsWord & 0x02) !== 0,
        faint: (flagsWord & 0x04) !== 0,
        blink: (flagsWord & 0x08) !== 0,
        inverse: (flagsWord & 0x10) !== 0,
        invisible: (flagsWord & 0x20) !== 0,
        strikethrough: (flagsWord & 0x40) !== 0,
        overline: (flagsWord & 0x80) !== 0,
        underline,
      };
      
      offset += 14;
      
      styles.set(styleId, { fgColor, bgColor, underlineColor, flags });
    }
    
    return styles;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
    }
    this.reconnectTimer = window.setTimeout(() => {
      debug.log("Attempting to reconnect...");
      this.connect();
    }, 2000);
  }

  disconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  /**
   * Send keyboard event (full fidelity for Kitty protocol support)
   */
  sendKey(message: KeyMessage): void {
    this.send(message);
  }

  /**
   * Send composed text (IME input)
   */
  sendText(message: TextMessage): void {
    this.send(message);
  }

  sendResize(cols: number, rows: number): void {
    this.send({ type: "resize", cols, rows });
  }

  /**
   * Scroll the terminal viewport by delta rows.
   * Negative values scroll up (toward history), positive scroll down.
   */
  sendScroll(delta: number): void {
    this.send({ type: "scroll", delta });
  }

  sendPing(): void {
    this.send({ type: "ping" });
  }

  /**
   * Request delta update from server.
   * @param gen Client's current generation
   * @param minRowId Oldest row ID client has cached
   */
  sendSync(gen: number, minRowId: number): void {
    this.send({ type: "sync", gen, minRowId });
  }

  /**
   * Request sync using current state
   */
  requestSync(): void {
    this.sendSync(this._generation, Number(this._minRowId));
  }

  /**
   * Apply a delta update to the local cache and notify as snapshot
   */
  private applyDelta(delta: BinaryDelta): void {
    debug.log(`Applying delta: gen ${this._generation} -> ${delta.gen}, ${delta.dirtyRows.length} dirty rows`);
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

    this._deltaCount++;
    this._cols = delta.cols;
    this._rows = delta.rows;

    // Apply each dirty row to cache
    for (const row of delta.dirtyRows) {
      const rowId = BigInt(row.id);
      const cells = this.decodeCellsFromBytes(row.cells);
      
      this._rowCache.set(rowId, cells);

      // Update min row ID tracking
      if (this._minRowId === 0n || rowId < this._minRowId) {
        this._minRowId = rowId;
      }
    }

    // Update generation
    this._generation = delta.gen;

    // Decode styles from delta
    const styles = this.decodeStyleTableFromBytes(delta.styles);

    // Merge with existing styles from last snapshot
    // Delta styles take precedence (they're the current ones)
    if (this._lastStyles) {
      for (const [id, style] of this._lastStyles) {
        if (!styles.has(id)) {
          styles.set(id, style);
        }
      }
    }
    this._lastStyles = styles;

    // Decode row IDs from delta (tells us which rows are in viewport)
    if (!delta.rowIds || delta.rowIds.length === 0) {
      console.error("Delta missing rowIds!", delta);
      // Fall back to last known rowIds
    }
    const rowIds = delta.rowIds ? this.decodeRowIdsFromBytes(delta.rowIds) : (this._lastRowIds ?? []);
    this._lastRowIds = rowIds;
    debug.log(`Decoded ${rowIds.length} rowIds:`, rowIds.map(String));
    debug.log(`Row cache size: ${this._rowCache.size}, keys:`, [...this._rowCache.keys()].map(String));
    
    // Check which rowIds are in cache
    // NOTE: rowId=0 IS valid (page serial 0, row index 0)
    const inCache = rowIds.filter(id => this._rowCache.has(id));
    const notInCache = rowIds.filter(id => !this._rowCache.has(id));
    debug.log(`RowIds in cache: ${inCache.length}, not in cache: ${notInCache.length}`);
    if (notInCache.length > 0) {
      debug.log(`Missing rowIds:`, notInCache.map(String));
      debug.log(`Cache has:`, [...this._rowCache.keys()].map(String));
    }

    // Build cells array from cache for current viewport
    // This requires knowing which row IDs are in the viewport
    // NOTE: rowId=0 IS valid, only undefined means "no row"
    const cells: Cell[] = [];
    let fromCache = 0;
    let filled = 0;
    for (let y = 0; y < delta.rows; y++) {
      const rowId = rowIds[y];
      if (rowId !== undefined) {
        const rowCells = this._rowCache.get(rowId);
        if (rowCells) {
          if (rowCells.length !== delta.cols) {
            console.warn(`Row ${y} (id=${rowId}) has ${rowCells.length} cells, expected ${delta.cols}`);
          }
          cells.push(...rowCells);
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
    debug.log(`Built cells: ${fromCache} rows from cache, ${filled} rows filled empty`);

    // Build merged snapshot
    const snapshot: TerminalSnapshot = {
      gen: delta.gen,
      cols: delta.cols,
      rows: delta.rows,
      cursor: {
        x: delta.cursor.x,
        y: delta.cursor.y,
        visible: delta.cursor.visible,
        style: delta.cursor.style as "block" | "underline" | "bar",
      },
      altScreen: delta.altScreen,
      scrollback: {
        totalRows: delta.vp.totalRows,
        viewportTop: delta.vp.viewportTop,
      },
      cells,
      styles,
      rowIds,
    };

    // Notify via onSnapshot (unified handler)
    this.onSnapshot?.(snapshot);

    // Extract title from delta if present
    const deltaTitle = (delta as any).title;
    if (deltaTitle && typeof deltaTitle === 'string') {
      debug.log("Delta includes title:", deltaTitle);
      this.onTitle?.(deltaTitle);
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
 */
export function cellsToLines(cells: Cell[], cols: number, rows: number): string[] {
  const lines: string[] = [];
  for (let y = 0; y < rows; y++) {
    let line = "";
    for (let x = 0; x < cols; x++) {
      const idx = y * cols + x;
      const cell = cells[idx];
      line += cell ? cellToChar(cell) : " ";
    }
    lines.push(line.trimEnd());
  }
  return lines;
}
