// WebSocket connection to dullahan server

import { decodeCellsFromBase64, cellToChar } from "../../../protocol/schema/cell";
import { decodeStyleTableFromBase64 } from "../../../protocol/schema/style";
import type { Cell } from "../../../protocol/schema/cell";
import type { StyleTable } from "../../../protocol/schema/style";
import type { KeyMessage } from "./keyboard";
import type { TextMessage } from "./ime";

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
  cells: Cell[]; // Decoded cell data
  styles: StyleTable; // Decoded style table
}

interface RawSnapshot {
  cols: number;
  rows: number;
  cursor: {
    x: number;
    y: number;
    visible: boolean;
    style: "block" | "underline" | "bar";
  };
  altScreen: boolean;
  cells: string; // Base64 encoded
  styles: string; // Base64 encoded
}

export type ServerMessage =
  | { type: "snapshot"; data: RawSnapshot }
  | { type: "output"; data: string }
  | { type: "pong" };

export type ClientMessage =
  | KeyMessage
  | TextMessage
  | { type: "resize"; cols: number; rows: number }
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

    this.ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data) as ServerMessage;
        this.handleMessage(msg);
      } catch (e) {
        console.error("Failed to parse message:", e, event.data);
      }
    };
  }

  private handleMessage(msg: ServerMessage): void {
    switch (msg.type) {
      case "snapshot":
        console.log("Received snapshot:", msg.data.cols, "x", msg.data.rows);
        // Decode cells and styles from base64
        const cells = decodeCellsFromBase64(msg.data.cells);
        const styles = decodeStyleTableFromBase64(msg.data.styles);
        const snapshot: TerminalSnapshot = {
          cols: msg.data.cols,
          rows: msg.data.rows,
          cursor: msg.data.cursor,
          altScreen: msg.data.altScreen,
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
