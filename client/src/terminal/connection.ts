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
}

/** Binary msgpack snapshot from server */
interface BinarySnapshot {
  type: "snapshot";
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
}

export type BinaryServerMessage =
  | BinarySnapshot
  | { type: "output"; data: string }
  | { type: "pong" };

export type ClientMessage =
  | KeyMessage
  | TextMessage
  | { type: "resize"; cols: number; rows: number }
  | { type: "scroll"; delta: number }  // Scroll viewport by delta rows (negative = up)
  | { type: "ping" };

export class TerminalConnection {
  private ws: WebSocket | null = null;
  private url: string;
  private reconnectTimer: number | null = null;

  public onSnapshot: ((snapshot: TerminalSnapshot) => void) | null = null;
  public onOutput: ((data: string) => void) | null = null;
  public onConnect: (() => void) | null = null;
  public onDisconnect: (() => void) | null = null;
  public onError: ((error: string) => void) | null = null;

  constructor(url: string = "ws://localhost:7681") {
    this.url = url;
  }

  connect(): void {
    if (this.ws) {
      this.ws.close();
    }

    console.log(`Connecting to ${this.url}...`);
    this.ws = new WebSocket(this.url);

    this.ws.onopen = () => {
      console.log("WebSocket connected");
      this.onConnect?.();
    };

    this.ws.onclose = () => {
      console.log("WebSocket disconnected");
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
          // Decompress with Snappy, then decode msgpack
          const compressed = new Uint8Array(event.data);
          const decompressed = SnappyJS.uncompress(compressed);
          const msg = decode(decompressed) as BinaryServerMessage;
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
        console.log("Received binary snapshot:", msg.cols, "x", msg.rows, 
          "scrollback:", msg.scrollback.totalRows, "top:", msg.scrollback.viewportTop);
        // Decode cells and styles from raw bytes
        const cells = this.decodeCellsFromBytes(msg.cells);
        const styles = this.decodeStyleTableFromBytes(msg.styles);
        const snapshot: TerminalSnapshot = {
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
        };
        this.onSnapshot?.(snapshot);
        break;
      case "output":
        this.onOutput?.(msg.data);
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
      console.log("Attempting to reconnect...");
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
