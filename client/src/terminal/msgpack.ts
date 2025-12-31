/**
 * MessagePack utilities for binary WebSocket communication.
 * 
 * Uses @msgpack/msgpack for efficient binary serialization.
 * This will replace JSON+base64 for snapshot data.
 */

import { encode, decode } from "@msgpack/msgpack";

// Re-export for convenience
export { encode, decode };

/**
 * Binary snapshot format from server.
 * Fields match the JSON format but cells/styles are raw Uint8Array.
 */
export interface BinarySnapshot {
  type: "snapshot";
  cols: number;
  rows: number;
  cursor: {
    x: number;
    y: number;
    visible: boolean;
    style: string;  // "block" | "underline" | "bar"
  };
  altScreen: boolean;
  scrollback: {
    totalRows: number;
    viewportTop: number;
  };
  cells: Uint8Array;   // Raw cell bytes (8 bytes per cell)
  styles: Uint8Array;  // Raw style table bytes
}

/**
 * All possible binary messages from server.
 */
export type BinaryServerMessage =
  | BinarySnapshot
  | { type: "output"; data: string }
  | { type: "pong" };

/**
 * Client messages (can be sent as msgpack or JSON).
 */
export interface BinaryKeyMessage {
  type: "key";
  key: string;
  code: string;
  state: "down" | "up" | "repeat";
  ctrl?: boolean;
  alt?: boolean;
  shift?: boolean;
  meta?: boolean;
}

export interface BinaryTextMessage {
  type: "text";
  data: string;
}

export interface BinaryResizeMessage {
  type: "resize";
  cols: number;
  rows: number;
}

export interface BinaryScrollMessage {
  type: "scroll";
  delta: number;
}

export interface BinaryPingMessage {
  type: "ping";
}

export type BinaryClientMessage =
  | BinaryKeyMessage
  | BinaryTextMessage
  | BinaryResizeMessage
  | BinaryScrollMessage
  | BinaryPingMessage;

/**
 * Encode a client message to msgpack binary format.
 */
export function encodeMessage(msg: BinaryClientMessage): Uint8Array {
  return encode(msg);
}

/**
 * Decode a server message from msgpack binary format.
 */
export function decodeMessage(data: ArrayBuffer | Uint8Array): BinaryServerMessage {
  return decode(data) as BinaryServerMessage;
}

/**
 * Check if data is binary (ArrayBuffer) or text (string).
 * WebSocket messages can be either.
 */
export function isBinaryMessage(data: unknown): data is ArrayBuffer {
  return data instanceof ArrayBuffer;
}

/**
 * Decode cells from raw bytes (no base64).
 * Each cell is 8 bytes matching ghostty's packed struct.
 */
export function decodeCellsFromBytes(data: Uint8Array): {
  codepoint: number;
  styleId: number;
  wide: boolean;
}[] {
  const cellSize = 8;
  const count = Math.floor(data.length / cellSize);
  const cells: { codepoint: number; styleId: number; wide: boolean }[] = [];

  for (let i = 0; i < count; i++) {
    const offset = i * cellSize;
    
    // First 3 bytes: codepoint (little-endian 21-bit value in 24 bits)
    const codepoint = (data[offset] ?? 0) | ((data[offset + 1] ?? 0) << 8) | ((data[offset + 2] ?? 0) << 16);
    
    // Byte 3: flags (wide is bit 0)
    const flagsByte = data[offset + 3] ?? 0;
    const wide = (flagsByte & 0x01) !== 0;
    
    // Bytes 6-7: style_id (little-endian u16)
    const styleId = (data[offset + 6] ?? 0) | ((data[offset + 7] ?? 0) << 8);
    
    cells.push({ codepoint, styleId, wide });
  }

  return cells;
}

/**
 * Decode style table from raw bytes.
 * Format: [count: u16] [id: u16, style: 14 bytes] ...
 */
export function decodeStyleTableFromBytes(data: Uint8Array): Map<number, {
  fgColor: { tag: number; r: number; g: number; b: number; index: number };
  bgColor: { tag: number; r: number; g: number; b: number; index: number };
  underlineColor: { tag: number; r: number; g: number; b: number; index: number };
  flags: {
    bold: boolean;
    italic: boolean;
    faint: boolean;
    blink: boolean;
    inverse: boolean;
    invisible: boolean;
    strikethrough: boolean;
    overline: boolean;
    underline: number;
  };
}> {
  const styles = new Map<number, {
    fgColor: { tag: number; r: number; g: number; b: number; index: number };
    bgColor: { tag: number; r: number; g: number; b: number; index: number };
    underlineColor: { tag: number; r: number; g: number; b: number; index: number };
    flags: {
      bold: boolean;
      italic: boolean;
      faint: boolean;
      blink: boolean;
      inverse: boolean;
      invisible: boolean;
      strikethrough: boolean;
      overline: boolean;
      underline: number;
    };
  }>();
  
  if (data.length < 2) return styles;
  
  const count = (data[0] ?? 0) | ((data[1] ?? 0) << 8);
  let offset = 2;
  
  for (let i = 0; i < count && offset + 16 <= data.length; i++) {
    const styleId = (data[offset] ?? 0) | ((data[offset + 1] ?? 0) << 8);
    offset += 2;
    
    // Decode color (4 bytes each): [tag, v0, v1, v2]
    const decodeColor = (start: number) => {
      const tag = data[start] ?? 0;
      return {
        tag,
        r: data[start + 1] ?? 0,
        g: data[start + 2] ?? 0,
        b: data[start + 3] ?? 0,
        index: data[start + 1] ?? 0,  // For palette colors
      };
    };
    
    const fgColor = decodeColor(offset);
    const bgColor = decodeColor(offset + 4);
    const underlineColor = decodeColor(offset + 8);
    
    // Flags (2 bytes, little-endian)
    const flagsWord = (data[offset + 12] ?? 0) | ((data[offset + 13] ?? 0) << 8);
    const flags = {
      bold: (flagsWord & 0x01) !== 0,
      italic: (flagsWord & 0x02) !== 0,
      faint: (flagsWord & 0x04) !== 0,
      blink: (flagsWord & 0x08) !== 0,
      inverse: (flagsWord & 0x10) !== 0,
      invisible: (flagsWord & 0x20) !== 0,
      strikethrough: (flagsWord & 0x40) !== 0,
      overline: (flagsWord & 0x80) !== 0,
      underline: (flagsWord >> 8) & 0x07,
    };
    
    offset += 14;
    
    styles.set(styleId, { fgColor, bgColor, underlineColor, flags });
  }
  
  return styles;
}
