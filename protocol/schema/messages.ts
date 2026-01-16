/**
 * Wire protocol message types for dullahan client-server communication.
 *
 * This file is the source of truth for all message types exchanged between
 * the TypeScript client and Zig server over WebSocket.
 *
 * See protocol/messages.md for wire format documentation.
 */

import type { LayoutNode, WindowLayout, LayoutTemplate } from "./layout";

// Re-export layout types used in messages
export type { WindowLayout, LayoutTemplate } from "./layout";

// =============================================================================
// Client → Server Messages
// =============================================================================

/**
 * Keyboard input event.
 * Full fidelity capture (1:1 with browser KeyboardEvent) for server-side
 * processing. Supports Kitty keyboard protocol.
 */
export interface KeyMessage {
  type: "key";
  paneId: number;
  key: string; // Logical key value ("a", "Enter", "ArrowUp")
  code: string; // Physical key code ("KeyA", "Enter", "ArrowUp")
  keyCode: number; // Legacy keyCode (deprecated but useful)
  state: "down" | "up";
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
  repeat: boolean;
  timestamp: number; // High-resolution timestamp (performance.now())
}

/**
 * IME composed text input.
 * Sent after IME composition completes (CJK, emoji, etc.).
 */
export interface TextMessage {
  type: "text";
  paneId: number;
  data: string; // UTF-8 composed text
  timestamp: number;
}

/**
 * Mouse input event.
 * Captures mouse button state and terminal cell coordinates.
 */
export interface MouseMessage {
  type: "mouse";
  paneId: number;
  button: number; // 0=left, 1=middle, 2=right
  x: number; // Column (0-indexed)
  y: number; // Row (0-indexed)
  px?: number; // Pixel X coordinate (for SGR-Pixels mode 1016)
  py?: number; // Pixel Y coordinate (for SGR-Pixels mode 1016)
  state: "down" | "up" | "move";
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
  timestamp: number;
}

/** Terminal resize request */
export interface ResizeMessage {
  type: "resize";
  paneId: number;
  cols: number;
  rows: number;
}

/** Scroll viewport request */
export interface ScrollMessage {
  type: "scroll";
  paneId: number;
  delta: number; // Scroll by delta rows (negative = up)
}

/** Request delta update from server */
export interface SyncMessage {
  type: "sync";
  paneId: number;
  gen: number; // Client's current generation
  minRowId: number; // Oldest cached row ID
}

/** Request focus on a pane */
export interface FocusMessage {
  type: "focus";
  paneId: number;
}

/** Client identification on connect */
export interface HelloMessage {
  type: "hello";
  clientId: string;
}

/** Request to become master */
export interface RequestMasterMessage {
  type: "request_master";
}

/** Create a new window */
export interface NewWindowMessage {
  type: "new_window";
  templateId?: string;
}

/** Close a window */
export interface CloseWindowMessage {
  type: "close_window";
  windowId: number;
}

/** Ping for keepalive */
export interface PingMessage {
  type: "ping";
}

/** Union of all client → server message types */
export type ClientMessage =
  | KeyMessage
  | TextMessage
  | MouseMessage
  | ResizeMessage
  | ScrollMessage
  | SyncMessage
  | FocusMessage
  | HelloMessage
  | RequestMasterMessage
  | NewWindowMessage
  | CloseWindowMessage
  | PingMessage;

// =============================================================================
// Server → Client Messages
// =============================================================================

/** Cursor state */
export interface CursorState {
  x: number;
  y: number;
  visible: boolean;
  style: string;
  blink?: boolean; // DEC Mode 12 state
}

/** Scrollback state */
export interface ScrollbackInfo {
  totalRows: number;
  viewportTop: number;
}

/**
 * Full terminal state snapshot.
 * Sent on connect and when delta sync fails.
 */
export interface BinarySnapshot {
  type: "snapshot";
  paneId: number;
  gen: number; // Generation counter for delta sync
  cols: number;
  rows: number;
  cursor: CursorState;
  altScreen: boolean;
  scrollback: ScrollbackInfo;
  cells: Uint8Array; // Raw cell bytes
  styles: Uint8Array; // Raw style bytes
  rowIds: Uint8Array; // Packed u64 row IDs (little-endian)
}

/**
 * Incremental terminal update.
 * Contains only changed rows since client's generation.
 */
export interface BinaryDelta {
  type: "delta";
  paneId: number;
  fromGen: number; // Generation this delta applies FROM
  gen: number; // New generation after applying (toGen)
  cols: number;
  rows: number;
  cursor: CursorState;
  altScreen: boolean;
  vp: ScrollbackInfo;
  dirtyRows: Array<{
    id: number; // Row ID (as number, fits in 53 bits)
    cells: Uint8Array; // Raw cell bytes for this row
  }>;
  rowIds: Uint8Array; // Packed u64 row IDs for viewport (little-endian)
  styles: Uint8Array; // Raw style bytes for dirty rows
}

/** Title update from server */
export interface TitleMessage {
  type: "title";
  paneId: number;
  title: string;
}

/** Bell notification (BEL 0x07 triggered) */
export interface BellMessage {
  type: "bell";
}

/** Focus change notification from server */
export interface FocusServerMessage {
  type: "focus";
  paneId: number;
}

/** Master client changed notification */
export interface MasterChangedMessage {
  type: "master_changed";
  masterId: string | null;
}

/** Pong response to ping */
export interface PongMessage {
  type: "pong";
}

/** Debug output from server */
export interface OutputMessage {
  type: "output";
  data: string;
}

// =============================================================================
// Layout Types (used in messages)
// =============================================================================

// WindowLayout and LayoutTemplate are imported and re-exported from ./layout.ts
// to maintain a single source of truth for these types.

/** Window information in layout message */
export interface WindowInfo {
  id: number;
  activePaneId: number;
  panes: number[];
  layout?: WindowLayout;
}

/** Layout message from server */
export interface LayoutMessage {
  type: "layout";
  activeWindowId: number;
  windows: WindowInfo[];
  templates?: LayoutTemplate[];
}

/** Layout update event (parsed from LayoutMessage) */
export interface LayoutUpdate {
  activeWindowId: number;
  windows: WindowInfo[];
  templates?: LayoutTemplate[];
}

/** Union of all server → client message types */
export type ServerMessage =
  | BinarySnapshot
  | BinaryDelta
  | TitleMessage
  | BellMessage
  | FocusServerMessage
  | MasterChangedMessage
  | LayoutMessage
  | OutputMessage
  | PongMessage;

// =============================================================================
// Delta Sync Types (used in client state)
// =============================================================================

/** Delta update event with applied changes */
export interface DeltaUpdate {
  paneId: number;
  gen: number;
  cols: number;
  rows: number;
  scrollback: ScrollbackInfo;
  changedRowIds: bigint[]; // Row IDs that were updated
}

// =============================================================================
// Row ID Utilities
// =============================================================================

/**
 * Decode row IDs from a packed Uint8Array.
 * Row IDs are packed as little-endian u64 values (8 bytes each).
 */
export function decodeRowIdsFromBytes(data: Uint8Array): bigint[] {
  if (!data || data.length === 0) {
    return [];
  }

  const rowIds: bigint[] = [];
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);

  for (let i = 0; i < data.length; i += 8) {
    const lo = view.getUint32(i, true);
    const hi = view.getUint32(i + 4, true);
    const rowId = BigInt(lo) | (BigInt(hi) << 32n);
    rowIds.push(rowId);
  }

  return rowIds;
}

/**
 * Encode row IDs to a packed Uint8Array.
 * Row IDs are packed as little-endian u64 values (8 bytes each).
 */
export function encodeRowIdsToBytes(rowIds: bigint[]): Uint8Array {
  const bytes = new Uint8Array(rowIds.length * 8);
  const view = new DataView(bytes.buffer);

  for (let i = 0; i < rowIds.length; i++) {
    const rowId = rowIds[i]!;
    const lo = Number(rowId & 0xffffffffn);
    const hi = Number((rowId >> 32n) & 0xffffffffn);
    view.setUint32(i * 8, lo, true);
    view.setUint32(i * 8 + 4, hi, true);
  }

  return bytes;
}
