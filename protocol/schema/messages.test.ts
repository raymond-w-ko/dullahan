/**
 * Tests for wire protocol message types.
 */

import { describe, test, expect } from "bun:test";
import type {
  // Client → Server
  KeyMessage,
  TextMessage,
  MouseMessage,
  ResizeMessage,
  ScrollMessage,
  SyncMessage,
  FocusMessage,
  HelloMessage,
  RequestMasterMessage,
  NewWindowMessage,
  PingMessage,
  ClientMessage,
  // Server → Client
  CursorState,
  ScrollbackInfo,
  SelectionBounds,
  BinarySnapshot,
  BinaryDelta,
  TitleMessage,
  BellMessage,
  FocusServerMessage,
  MasterChangedMessage,
  PongMessage,
  OutputMessage,
  LayoutMessage,
  WindowInfo,
  ServerMessage,
  DeltaUpdate,
} from "./messages";
import {
  decodeRowIdsFromBytes,
  encodeRowIdsToBytes,
  normalizeSelectionBounds,
} from "./messages";

// =============================================================================
// Client → Server Messages
// =============================================================================

describe("Client → Server Messages", () => {
  describe("KeyMessage", () => {
    test("valid key message structure", () => {
      const msg: KeyMessage = {
        type: "key",
        paneId: 1,
        key: "a",
        code: "KeyA",
        keyCode: 65,
        state: "down",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        repeat: false,
        timestamp: 1234.5,
      };

      expect(msg.type).toBe("key");
      expect(msg.paneId).toBe(1);
      expect(msg.key).toBe("a");
      expect(msg.code).toBe("KeyA");
      expect(msg.keyCode).toBe(65);
      expect(msg.state).toBe("down");
      expect(msg.repeat).toBe(false);
    });

    test("key message with modifiers", () => {
      const msg: KeyMessage = {
        type: "key",
        paneId: 0,
        key: "c",
        code: "KeyC",
        keyCode: 67,
        state: "down",
        ctrl: true,
        alt: false,
        shift: false,
        meta: false,
        repeat: false,
        timestamp: 0,
      };

      expect(msg.ctrl).toBe(true);
      expect(msg.alt).toBe(false);
    });

    test("key release state", () => {
      const msg: KeyMessage = {
        type: "key",
        paneId: 1,
        key: "Enter",
        code: "Enter",
        keyCode: 13,
        state: "up",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        repeat: false,
        timestamp: 100,
      };

      expect(msg.state).toBe("up");
    });

    test("key repeat event", () => {
      const msg: KeyMessage = {
        type: "key",
        paneId: 1,
        key: "a",
        code: "KeyA",
        keyCode: 65,
        state: "down",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        repeat: true,
        timestamp: 200,
      };

      expect(msg.repeat).toBe(true);
    });
  });

  describe("TextMessage", () => {
    test("simple text input", () => {
      const msg: TextMessage = {
        type: "text",
        paneId: 1,
        data: "hello",
        timestamp: 1234.5,
      };

      expect(msg.type).toBe("text");
      expect(msg.data).toBe("hello");
    });

    test("IME composed text (CJK)", () => {
      const msg: TextMessage = {
        type: "text",
        paneId: 1,
        data: "你好世界",
        timestamp: 1000,
      };

      expect(msg.data).toBe("你好世界");
      expect(msg.data.length).toBe(4);
    });

    test("emoji text", () => {
      const msg: TextMessage = {
        type: "text",
        paneId: 1,
        data: "👋🏼",
        timestamp: 0,
      };

      expect(msg.data).toBe("👋🏼");
    });
  });

  describe("MouseMessage", () => {
    test("mouse click", () => {
      const msg: MouseMessage = {
        type: "mouse",
        paneId: 1,
        button: 0,
        x: 10,
        y: 5,
        state: "down",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        timestamp: 0,
      };

      expect(msg.type).toBe("mouse");
      expect(msg.button).toBe(0);
      expect(msg.x).toBe(10);
      expect(msg.y).toBe(5);
      expect(msg.state).toBe("down");
    });

    test("mouse release", () => {
      const msg: MouseMessage = {
        type: "mouse",
        paneId: 1,
        button: 0,
        x: 10,
        y: 5,
        state: "up",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        timestamp: 0,
      };

      expect(msg.state).toBe("up");
    });

    test("mouse move", () => {
      const msg: MouseMessage = {
        type: "mouse",
        paneId: 1,
        button: 0,
        x: 15,
        y: 8,
        state: "move",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        timestamp: 0,
      };

      expect(msg.state).toBe("move");
    });

    test("right click with modifier", () => {
      const msg: MouseMessage = {
        type: "mouse",
        paneId: 1,
        button: 2,
        x: 0,
        y: 0,
        state: "down",
        ctrl: true,
        alt: false,
        shift: false,
        meta: false,
        timestamp: 0,
      };

      expect(msg.button).toBe(2);
      expect(msg.ctrl).toBe(true);
    });

    test("pixel coordinates (SGR-Pixels mode)", () => {
      const msg: MouseMessage = {
        type: "mouse",
        paneId: 1,
        button: 0,
        x: 10,
        y: 5,
        px: 85,
        py: 75,
        state: "down",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        timestamp: 0,
      };

      expect(msg.px).toBe(85);
      expect(msg.py).toBe(75);
    });
  });

  describe("ResizeMessage", () => {
    test("standard terminal size", () => {
      const msg: ResizeMessage = {
        type: "resize",
        paneId: 1,
        cols: 80,
        rows: 24,
        cellWidth: 9.5,
        cellHeight: 18,
      };

      expect(msg.type).toBe("resize");
      expect(msg.cols).toBe(80);
      expect(msg.rows).toBe(24);
      expect(msg.cellWidth).toBe(9.5);
      expect(msg.cellHeight).toBe(18);
    });

    test("large terminal", () => {
      const msg: ResizeMessage = {
        type: "resize",
        paneId: 1,
        cols: 300,
        rows: 100,
      };

      expect(msg.cols).toBe(300);
      expect(msg.rows).toBe(100);
    });
  });

  describe("ScrollMessage", () => {
    test("scroll up", () => {
      const msg: ScrollMessage = {
        type: "scroll",
        paneId: 1,
        delta: -5,
      };

      expect(msg.type).toBe("scroll");
      expect(msg.delta).toBe(-5);
    });

    test("scroll down", () => {
      const msg: ScrollMessage = {
        type: "scroll",
        paneId: 1,
        delta: 10,
      };

      expect(msg.delta).toBe(10);
    });
  });

  describe("SyncMessage", () => {
    test("request delta sync", () => {
      const msg: SyncMessage = {
        type: "sync",
        paneId: 1,
        gen: 42,
        minRowId: 1000,
      };

      expect(msg.type).toBe("sync");
      expect(msg.gen).toBe(42);
      expect(msg.minRowId).toBe(1000);
    });
  });

  describe("FocusMessage", () => {
    test("focus request", () => {
      const msg: FocusMessage = {
        type: "focus",
        paneId: 2,
      };

      expect(msg.type).toBe("focus");
      expect(msg.paneId).toBe(2);
    });
  });

  describe("HelloMessage", () => {
    test("client identification", () => {
      const msg: HelloMessage = {
        type: "hello",
        clientId: "client-abc-123",
      };

      expect(msg.type).toBe("hello");
      expect(msg.clientId).toBe("client-abc-123");
    });
  });

  describe("RequestMasterMessage", () => {
    test("request master status", () => {
      const msg: RequestMasterMessage = {
        type: "request_master",
      };

      expect(msg.type).toBe("request_master");
    });
  });

  describe("NewWindowMessage", () => {
    test("create new window (default template)", () => {
      const msg: NewWindowMessage = {
        type: "new_window",
      };

      expect(msg.type).toBe("new_window");
      expect(msg.templateId).toBeUndefined();
    });

    test("create new window with template", () => {
      const msg: NewWindowMessage = {
        type: "new_window",
        templateId: "2x2",
      };

      expect(msg.templateId).toBe("2x2");
    });
  });

  describe("PingMessage", () => {
    test("ping for keepalive", () => {
      const msg: PingMessage = {
        type: "ping",
      };

      expect(msg.type).toBe("ping");
    });
  });
});

// =============================================================================
// Server → Client Messages
// =============================================================================

describe("Server → Client Messages", () => {
  describe("CursorState", () => {
    test("visible block cursor", () => {
      const cursor: CursorState = {
        x: 0,
        y: 0,
        visible: true,
        style: "block",
      };

      expect(cursor.visible).toBe(true);
      expect(cursor.style).toBe("block");
    });

    test("blinking bar cursor", () => {
      const cursor: CursorState = {
        x: 10,
        y: 5,
        visible: true,
        style: "bar",
        blink: true,
      };

      expect(cursor.blink).toBe(true);
      expect(cursor.style).toBe("bar");
    });

    test("hidden cursor", () => {
      const cursor: CursorState = {
        x: 0,
        y: 0,
        visible: false,
        style: "block",
      };

      expect(cursor.visible).toBe(false);
    });
  });

  describe("ScrollbackInfo", () => {
    test("no scrollback", () => {
      const info: ScrollbackInfo = {
        totalRows: 24,
        viewportTop: 0,
      };

      expect(info.totalRows).toBe(24);
      expect(info.viewportTop).toBe(0);
    });

    test("scrolled up in scrollback", () => {
      const info: ScrollbackInfo = {
        totalRows: 1000,
        viewportTop: 500,
      };

      expect(info.totalRows).toBe(1000);
      expect(info.viewportTop).toBe(500);
    });
  });

  describe("BinarySnapshot", () => {
    test("minimal snapshot", () => {
      const msg: BinarySnapshot = {
        type: "snapshot",
        paneId: 1,
        gen: 1,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: false,
        scrollback: { totalRows: 24, viewportTop: 0 },
        cells: new Uint8Array(0),
        styles: new Uint8Array(0),
        rowIds: new Uint8Array(0),
      };

      expect(msg.type).toBe("snapshot");
      expect(msg.paneId).toBe(1);
      expect(msg.gen).toBe(1);
      expect(msg.cols).toBe(80);
      expect(msg.rows).toBe(24);
      expect(msg.altScreen).toBe(false);
    });

    test("snapshot with cell data", () => {
      const cellData = new Uint8Array([0x41, 0, 0, 0, 0, 0, 0, 0]); // 'A'
      const msg: BinarySnapshot = {
        type: "snapshot",
        paneId: 1,
        gen: 42,
        cols: 1,
        rows: 1,
        cursor: { x: 1, y: 0, visible: true, style: "block" },
        altScreen: false,
        scrollback: { totalRows: 1, viewportTop: 0 },
        cells: cellData,
        styles: new Uint8Array(0),
        rowIds: new Uint8Array(8),
      };

      expect(msg.cells.byteLength).toBe(8);
    });

    test("alternate screen active", () => {
      const msg: BinarySnapshot = {
        type: "snapshot",
        paneId: 1,
        gen: 1,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: true,
        scrollback: { totalRows: 24, viewportTop: 0 },
        cells: new Uint8Array(0),
        styles: new Uint8Array(0),
        rowIds: new Uint8Array(0),
      };

      expect(msg.altScreen).toBe(true);
    });
  });

  describe("BinaryDelta", () => {
    test("minimal delta (no changes)", () => {
      const msg: BinaryDelta = {
        type: "delta",
        paneId: 1,
        fromGen: 1,
        gen: 2,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: false,
        vp: { totalRows: 24, viewportTop: 0 },
        dirtyRows: [],
        rowIds: new Uint8Array(0),
        styles: new Uint8Array(0),
      };

      expect(msg.type).toBe("delta");
      expect(msg.fromGen).toBe(1);
      expect(msg.gen).toBe(2);
      expect(msg.dirtyRows.length).toBe(0);
    });

    test("delta with dirty rows", () => {
      const msg: BinaryDelta = {
        type: "delta",
        paneId: 1,
        fromGen: 10,
        gen: 15,
        cols: 80,
        rows: 24,
        cursor: { x: 5, y: 3, visible: true, style: "block" },
        altScreen: false,
        vp: { totalRows: 100, viewportTop: 76 },
        dirtyRows: [
          { id: 1003, cells: new Uint8Array(640) },
          { id: 1005, cells: new Uint8Array(640) },
        ],
        rowIds: new Uint8Array(192),
        styles: new Uint8Array(0),
      };

      expect(msg.dirtyRows.length).toBe(2);
      expect(msg.dirtyRows[0].id).toBe(1003);
      expect(msg.dirtyRows[1].id).toBe(1005);
    });
  });

  describe("TitleMessage", () => {
    test("title update", () => {
      const msg: TitleMessage = {
        type: "title",
        paneId: 1,
        title: "vim - file.txt",
      };

      expect(msg.type).toBe("title");
      expect(msg.title).toBe("vim - file.txt");
    });

    test("empty title", () => {
      const msg: TitleMessage = {
        type: "title",
        paneId: 1,
        title: "",
      };

      expect(msg.title).toBe("");
    });
  });

  describe("BellMessage", () => {
    test("bell notification", () => {
      const msg: BellMessage = {
        type: "bell",
      };

      expect(msg.type).toBe("bell");
    });
  });

  describe("FocusServerMessage", () => {
    test("focus change from server", () => {
      const msg: FocusServerMessage = {
        type: "focus",
        paneId: 2,
      };

      expect(msg.type).toBe("focus");
      expect(msg.paneId).toBe(2);
    });
  });

  describe("MasterChangedMessage", () => {
    test("new master assigned", () => {
      const msg: MasterChangedMessage = {
        type: "master_changed",
        masterId: "client-xyz-789",
      };

      expect(msg.type).toBe("master_changed");
      expect(msg.masterId).toBe("client-xyz-789");
    });

    test("no master (null)", () => {
      const msg: MasterChangedMessage = {
        type: "master_changed",
        masterId: null,
      };

      expect(msg.masterId).toBeNull();
    });
  });

  describe("PongMessage", () => {
    test("pong response", () => {
      const msg: PongMessage = {
        type: "pong",
      };

      expect(msg.type).toBe("pong");
    });
  });

  describe("OutputMessage", () => {
    test("debug output", () => {
      const msg: OutputMessage = {
        type: "output",
        data: "Debug: connection established",
      };

      expect(msg.type).toBe("output");
      expect(msg.data).toBe("Debug: connection established");
    });
  });

  describe("LayoutMessage", () => {
    test("single window layout", () => {
      const windowInfo: WindowInfo = {
        id: 0,
        activePaneId: 1,
        panes: [1, 2, 3],
      };

      const msg: LayoutMessage = {
        type: "layout",
        activeWindowId: 0,
        windows: [windowInfo],
      };

      expect(msg.type).toBe("layout");
      expect(msg.activeWindowId).toBe(0);
      expect(msg.windows.length).toBe(1);
      expect(msg.windows[0].panes).toEqual([1, 2, 3]);
    });

    test("multiple windows with templates", () => {
      const msg: LayoutMessage = {
        type: "layout",
        activeWindowId: 1,
        windows: [
          { id: 0, activePaneId: 0, panes: [0, 1, 2] },
          { id: 1, activePaneId: 3, panes: [3, 4] },
        ],
        templates: [
          { id: "single", name: "Single Pane", root: { type: "pane", width: 100, height: 100 } },
          {
            id: "2-col",
            name: "Two Columns",
            root: {
              type: "container",
              width: 100,
              height: 100,
              children: [
                { type: "pane", width: 50, height: 100 },
                { type: "pane", width: 50, height: 100 },
              ],
            },
          },
        ],
      };

      expect(msg.windows.length).toBe(2);
      expect(msg.templates?.length).toBe(2);
      expect(msg.templates?.[0].id).toBe("single");
    });
  });
});

// =============================================================================
// Delta Sync Types
// =============================================================================

describe("Delta Sync Types", () => {
  describe("DeltaUpdate", () => {
    test("delta update with changed rows", () => {
      const update: DeltaUpdate = {
        paneId: 1,
        gen: 50,
        cols: 80,
        rows: 24,
        scrollback: { totalRows: 100, viewportTop: 76 },
        changedRowIds: [1000n, 1001n, 1005n],
      };

      expect(update.changedRowIds.length).toBe(3);
      expect(update.changedRowIds[0]).toBe(1000n);
    });
  });
});

// =============================================================================
// Row ID Utilities
// =============================================================================

describe("Row ID Utilities", () => {
  describe("decodeRowIdsFromBytes", () => {
    test("empty array", () => {
      const result = decodeRowIdsFromBytes(new Uint8Array(0));
      expect(result).toEqual([]);
    });

    test("single row ID", () => {
      // Row ID 1000 = 0x3E8 in little-endian u64
      const bytes = new Uint8Array([0xe8, 0x03, 0, 0, 0, 0, 0, 0]);
      const result = decodeRowIdsFromBytes(bytes);

      expect(result.length).toBe(1);
      expect(result[0]).toBe(1000n);
    });

    test("multiple row IDs", () => {
      const bytes = new Uint8Array(16);
      const view = new DataView(bytes.buffer);

      // Row ID 1000
      view.setUint32(0, 1000, true);
      view.setUint32(4, 0, true);

      // Row ID 2000
      view.setUint32(8, 2000, true);
      view.setUint32(12, 0, true);

      const result = decodeRowIdsFromBytes(bytes);

      expect(result.length).toBe(2);
      expect(result[0]).toBe(1000n);
      expect(result[1]).toBe(2000n);
    });

    test("large row ID (uses high 32 bits)", () => {
      const bytes = new Uint8Array(8);
      const view = new DataView(bytes.buffer);

      // Row ID = 0x100000001 (larger than 32 bits)
      view.setUint32(0, 1, true); // low
      view.setUint32(4, 1, true); // high

      const result = decodeRowIdsFromBytes(bytes);

      expect(result.length).toBe(1);
      expect(result[0]).toBe(0x100000001n);
    });

    test("null/undefined handling", () => {
      const result = decodeRowIdsFromBytes(null as unknown as Uint8Array);
      expect(result).toEqual([]);
    });
  });

  describe("encodeRowIdsToBytes", () => {
    test("empty array", () => {
      const result = encodeRowIdsToBytes([]);
      expect(result.byteLength).toBe(0);
    });

    test("single row ID", () => {
      const result = encodeRowIdsToBytes([1000n]);

      expect(result.byteLength).toBe(8);

      const view = new DataView(result.buffer);
      expect(view.getUint32(0, true)).toBe(1000);
      expect(view.getUint32(4, true)).toBe(0);
    });

    test("multiple row IDs", () => {
      const result = encodeRowIdsToBytes([1000n, 2000n, 3000n]);

      expect(result.byteLength).toBe(24);

      const view = new DataView(result.buffer);
      expect(view.getUint32(0, true)).toBe(1000);
      expect(view.getUint32(8, true)).toBe(2000);
      expect(view.getUint32(16, true)).toBe(3000);
    });

    test("large row ID", () => {
      const result = encodeRowIdsToBytes([0x100000001n]);

      const view = new DataView(result.buffer);
      expect(view.getUint32(0, true)).toBe(1);
      expect(view.getUint32(4, true)).toBe(1);
    });
  });

  describe("encode/decode round-trip", () => {
    test("round-trip single value", () => {
      const original = [42n];
      const encoded = encodeRowIdsToBytes(original);
      const decoded = decodeRowIdsFromBytes(encoded);

      expect(decoded).toEqual(original);
    });

    test("round-trip multiple values", () => {
      const original = [1000n, 2000n, 3000n, 4000n, 5000n];
      const encoded = encodeRowIdsToBytes(original);
      const decoded = decodeRowIdsFromBytes(encoded);

      expect(decoded).toEqual(original);
    });

    test("round-trip large values", () => {
      const original = [0xffffffffffffffffn >> 11n, 0x123456789abcdefn, 1n];
      const encoded = encodeRowIdsToBytes(original);
      const decoded = decodeRowIdsFromBytes(encoded);

      expect(decoded).toEqual(original);
    });
  });
});

// =============================================================================
// Message Discrimination (Union Types)
// =============================================================================

describe("Message Discrimination", () => {
  describe("ClientMessage union", () => {
    test("discriminate client messages by type field", () => {
      const messages: ClientMessage[] = [
        {
          type: "key",
          paneId: 1,
          key: "a",
          code: "KeyA",
          keyCode: 65,
          state: "down",
          ctrl: false,
          alt: false,
          shift: false,
          meta: false,
          repeat: false,
          timestamp: 0,
        },
        { type: "text", paneId: 1, data: "hello", timestamp: 0 },
        { type: "resize", paneId: 1, cols: 80, rows: 24 },
        { type: "scroll", paneId: 1, delta: -5 },
        { type: "sync", paneId: 1, gen: 1, minRowId: 0 },
        { type: "focus", paneId: 1 },
        { type: "hello", clientId: "test" },
        { type: "request_master" },
        { type: "new_window" },
        { type: "ping" },
      ];

      const types = messages.map((m) => m.type);
      expect(types).toContain("key");
      expect(types).toContain("text");
      expect(types).toContain("resize");
      expect(types).toContain("scroll");
      expect(types).toContain("sync");
      expect(types).toContain("focus");
      expect(types).toContain("hello");
      expect(types).toContain("request_master");
      expect(types).toContain("new_window");
      expect(types).toContain("ping");
    });

    test("type narrowing works correctly", () => {
      const msg: ClientMessage = {
        type: "key",
        paneId: 1,
        key: "Enter",
        code: "Enter",
        keyCode: 13,
        state: "down",
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
        repeat: false,
        timestamp: 0,
      };

      if (msg.type === "key") {
        expect(msg.key).toBe("Enter");
        expect(msg.code).toBe("Enter");
      }
    });
  });

  describe("ServerMessage union", () => {
    test("discriminate server messages by type field", () => {
      const messages: ServerMessage[] = [
        {
          type: "snapshot",
          paneId: 1,
          gen: 1,
          cols: 80,
          rows: 24,
          cursor: { x: 0, y: 0, visible: true, style: "block" },
          altScreen: false,
          scrollback: { totalRows: 24, viewportTop: 0 },
          cells: new Uint8Array(0),
          styles: new Uint8Array(0),
          rowIds: new Uint8Array(0),
        },
        {
          type: "delta",
          paneId: 1,
          fromGen: 1,
          gen: 2,
          cols: 80,
          rows: 24,
          cursor: { x: 0, y: 0, visible: true, style: "block" },
          altScreen: false,
          vp: { totalRows: 24, viewportTop: 0 },
          dirtyRows: [],
          rowIds: new Uint8Array(0),
          styles: new Uint8Array(0),
        },
        { type: "title", paneId: 1, title: "test" },
        { type: "bell" },
        { type: "focus", paneId: 1 },
        { type: "master_changed", masterId: null },
        { type: "layout", activeWindowId: 0, windows: [] },
        { type: "output", data: "test" },
        { type: "pong" },
      ];

      const types = messages.map((m) => m.type);
      expect(types).toContain("snapshot");
      expect(types).toContain("delta");
      expect(types).toContain("title");
      expect(types).toContain("bell");
      expect(types).toContain("focus");
      expect(types).toContain("master_changed");
      expect(types).toContain("layout");
      expect(types).toContain("output");
      expect(types).toContain("pong");
    });

    test("type narrowing for snapshot", () => {
      const msg: ServerMessage = {
        type: "snapshot",
        paneId: 1,
        gen: 42,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: false,
        scrollback: { totalRows: 24, viewportTop: 0 },
        cells: new Uint8Array(0),
        styles: new Uint8Array(0),
        rowIds: new Uint8Array(0),
      };

      if (msg.type === "snapshot") {
        expect(msg.gen).toBe(42);
        expect(msg.cols).toBe(80);
        expect(msg.rows).toBe(24);
      }
    });

    test("type narrowing for delta", () => {
      const msg: ServerMessage = {
        type: "delta",
        paneId: 1,
        fromGen: 10,
        gen: 15,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: false,
        vp: { totalRows: 24, viewportTop: 0 },
        dirtyRows: [{ id: 1000, cells: new Uint8Array(8) }],
        rowIds: new Uint8Array(0),
        styles: new Uint8Array(0),
      };

      if (msg.type === "delta") {
        expect(msg.fromGen).toBe(10);
        expect(msg.gen).toBe(15);
        expect(msg.dirtyRows.length).toBe(1);
      }
    });
  });
});

// =============================================================================
// Selection Bounds
// =============================================================================

describe("Selection Bounds", () => {
  describe("SelectionBounds interface", () => {
    test("normal selection", () => {
      const sel: SelectionBounds = {
        startX: 0,
        startY: 0,
        endX: 10,
        endY: 5,
        isRectangle: false,
      };

      expect(sel.startX).toBe(0);
      expect(sel.startY).toBe(0);
      expect(sel.endX).toBe(10);
      expect(sel.endY).toBe(5);
      expect(sel.isRectangle).toBe(false);
    });

    test("rectangular selection", () => {
      const sel: SelectionBounds = {
        startX: 5,
        startY: 2,
        endX: 15,
        endY: 8,
        isRectangle: true,
      };

      expect(sel.isRectangle).toBe(true);
    });

    test("single cell selection (start equals end)", () => {
      const sel: SelectionBounds = {
        startX: 5,
        startY: 3,
        endX: 5,
        endY: 3,
        isRectangle: false,
      };

      expect(sel.startX).toBe(sel.endX);
      expect(sel.startY).toBe(sel.endY);
    });

    test("selection at terminal edge", () => {
      const sel: SelectionBounds = {
        startX: 0,
        startY: 0,
        endX: 79,
        endY: 23,
        isRectangle: false,
      };

      expect(sel.startX).toBe(0);
      expect(sel.startY).toBe(0);
      expect(sel.endX).toBe(79);
      expect(sel.endY).toBe(23);
    });
  });

  describe("normalizeSelectionBounds", () => {
    test("already normalized selection (start before end)", () => {
      const sel: SelectionBounds = {
        startX: 0,
        startY: 0,
        endX: 10,
        endY: 5,
        isRectangle: false,
      };

      const normalized = normalizeSelectionBounds(sel);

      expect(normalized.startX).toBe(0);
      expect(normalized.startY).toBe(0);
      expect(normalized.endX).toBe(10);
      expect(normalized.endY).toBe(5);
      expect(normalized.isRectangle).toBe(false);
    });

    test("reversed selection (end Y before start Y)", () => {
      const sel: SelectionBounds = {
        startX: 10,
        startY: 5,
        endX: 0,
        endY: 0,
        isRectangle: false,
      };

      const normalized = normalizeSelectionBounds(sel);

      expect(normalized.startX).toBe(0);
      expect(normalized.startY).toBe(0);
      expect(normalized.endX).toBe(10);
      expect(normalized.endY).toBe(5);
    });

    test("reversed selection on same row (end X before start X)", () => {
      const sel: SelectionBounds = {
        startX: 20,
        startY: 3,
        endX: 5,
        endY: 3,
        isRectangle: false,
      };

      const normalized = normalizeSelectionBounds(sel);

      expect(normalized.startX).toBe(5);
      expect(normalized.startY).toBe(3);
      expect(normalized.endX).toBe(20);
      expect(normalized.endY).toBe(3);
    });

    test("preserves isRectangle flag", () => {
      const sel: SelectionBounds = {
        startX: 10,
        startY: 5,
        endX: 0,
        endY: 0,
        isRectangle: true,
      };

      const normalized = normalizeSelectionBounds(sel);

      expect(normalized.isRectangle).toBe(true);
    });

    test("single cell selection unchanged", () => {
      const sel: SelectionBounds = {
        startX: 5,
        startY: 3,
        endX: 5,
        endY: 3,
        isRectangle: false,
      };

      const normalized = normalizeSelectionBounds(sel);

      expect(normalized.startX).toBe(5);
      expect(normalized.startY).toBe(3);
      expect(normalized.endX).toBe(5);
      expect(normalized.endY).toBe(3);
    });

    test("same row selection already normalized", () => {
      const sel: SelectionBounds = {
        startX: 5,
        startY: 3,
        endX: 20,
        endY: 3,
        isRectangle: false,
      };

      const normalized = normalizeSelectionBounds(sel);

      expect(normalized.startX).toBe(5);
      expect(normalized.endX).toBe(20);
    });

    test("rectangular selection normalization", () => {
      const sel: SelectionBounds = {
        startX: 30,
        startY: 10,
        endX: 10,
        endY: 2,
        isRectangle: true,
      };

      const normalized = normalizeSelectionBounds(sel);

      // Y values swapped because startY > endY
      expect(normalized.startY).toBe(2);
      expect(normalized.endY).toBe(10);
      // X values also swapped in the swap operation
      expect(normalized.startX).toBe(10);
      expect(normalized.endX).toBe(30);
    });

    test("does not mutate original selection", () => {
      const original: SelectionBounds = {
        startX: 10,
        startY: 5,
        endX: 0,
        endY: 0,
        isRectangle: false,
      };

      normalizeSelectionBounds(original);

      // Original should be unchanged
      expect(original.startX).toBe(10);
      expect(original.startY).toBe(5);
      expect(original.endX).toBe(0);
      expect(original.endY).toBe(0);
    });
  });

  describe("SelectionBounds in snapshots", () => {
    test("snapshot with selection", () => {
      const msg: BinarySnapshot = {
        type: "snapshot",
        paneId: 1,
        gen: 1,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: false,
        scrollback: { totalRows: 24, viewportTop: 0 },
        cells: new Uint8Array(0),
        styles: new Uint8Array(0),
        rowIds: new Uint8Array(0),
        selection: {
          startX: 5,
          startY: 2,
          endX: 15,
          endY: 2,
          isRectangle: false,
        },
      };

      expect(msg.selection).toBeDefined();
      expect(msg.selection?.startX).toBe(5);
      expect(msg.selection?.endX).toBe(15);
    });

    test("snapshot without selection", () => {
      const msg: BinarySnapshot = {
        type: "snapshot",
        paneId: 1,
        gen: 1,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: false,
        scrollback: { totalRows: 24, viewportTop: 0 },
        cells: new Uint8Array(0),
        styles: new Uint8Array(0),
        rowIds: new Uint8Array(0),
      };

      expect(msg.selection).toBeUndefined();
    });
  });

  describe("SelectionBounds in deltas", () => {
    test("delta with selection", () => {
      const msg: BinaryDelta = {
        type: "delta",
        paneId: 1,
        fromGen: 1,
        gen: 2,
        cols: 80,
        rows: 24,
        cursor: { x: 0, y: 0, visible: true, style: "block" },
        altScreen: false,
        vp: { totalRows: 24, viewportTop: 0 },
        dirtyRows: [],
        rowIds: new Uint8Array(0),
        styles: new Uint8Array(0),
        selection: {
          startX: 0,
          startY: 0,
          endX: 79,
          endY: 23,
          isRectangle: true,
        },
      };

      expect(msg.selection).toBeDefined();
      expect(msg.selection?.isRectangle).toBe(true);
    });
  });
});
