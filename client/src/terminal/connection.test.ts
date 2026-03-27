import { beforeEach, describe, expect, mock, test } from "bun:test";
import { TerminalConnection } from "./connection";
import type { KeyMessage } from "./keyboard";
import type { TextMessage } from "../../../protocol/schema/messages";

const sessionStorageState = new Map<string, string>();
const localStorageState = new Map<string, string>();

const mockSessionStorage = {
  getItem: (key: string) => sessionStorageState.get(key) ?? null,
  setItem: (key: string, value: string) => sessionStorageState.set(key, value),
  removeItem: (key: string) => sessionStorageState.delete(key),
  clear: () => sessionStorageState.clear(),
};

const mockLocalStorage = {
  getItem: (key: string) => localStorageState.get(key) ?? null,
  setItem: (key: string, value: string) => localStorageState.set(key, value),
  removeItem: (key: string) => localStorageState.delete(key),
  clear: () => localStorageState.clear(),
};

const mockWindow = {
  location: {
    protocol: "http:",
    host: "localhost:3000",
    search: "",
  },
  setTimeout: globalThis.setTimeout.bind(globalThis),
  clearTimeout: globalThis.clearTimeout.bind(globalThis),
};

(globalThis as unknown as { sessionStorage: typeof mockSessionStorage }).sessionStorage = mockSessionStorage;
(globalThis as unknown as { localStorage: typeof mockLocalStorage }).localStorage = mockLocalStorage;
(globalThis as unknown as { window: typeof mockWindow }).window = mockWindow;

function createMasterConnection(): TerminalConnection {
  const connection = new TerminalConnection("ws://localhost:7681");
  (connection as any)._masterId = connection.clientId;
  return connection;
}

beforeEach(() => {
  sessionStorageState.clear();
  localStorageState.clear();
});

describe("TerminalConnection input tail-follow", () => {
  test("scrolls to bottom before printable key input", () => {
    const connection = createMasterConnection();
    const sent = mock((_message: unknown) => {});
    (connection as any).send = sent;

    const paneState = (connection as any).getPaneState(7);
    paneState.followTail = false;

    const message: KeyMessage = {
      type: "key",
      paneId: 7,
      key: "a",
      code: "KeyA",
      keyCode: 65,
      state: "down",
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
      repeat: false,
      timestamp: 1,
    };

    connection.sendKey(message);

    expect(sent.mock.calls).toEqual([
      [{ type: "scroll", paneId: 7, delta: 999999 }],
      [message],
    ]);
    expect(paneState.followTail).toBe(true);
  });

  test("does not scroll to bottom for modifier-only key input", () => {
    const connection = createMasterConnection();
    const sent = mock((_message: unknown) => {});
    (connection as any).send = sent;

    const paneState = (connection as any).getPaneState(7);
    paneState.followTail = false;

    const message: KeyMessage = {
      type: "key",
      paneId: 7,
      key: "Shift",
      code: "ShiftLeft",
      keyCode: 16,
      state: "down",
      ctrl: false,
      alt: false,
      shift: true,
      meta: false,
      repeat: false,
      timestamp: 1,
    };

    connection.sendKey(message);

    expect(sent.mock.calls).toEqual([[message]]);
    expect(paneState.followTail).toBe(false);
  });

  test("scrolls to bottom before IME text input", () => {
    const connection = createMasterConnection();
    const sent = mock((_message: unknown) => {});
    (connection as any).send = sent;

    const paneState = (connection as any).getPaneState(9);
    paneState.followTail = false;

    const message: TextMessage = {
      type: "text",
      paneId: 9,
      data: "あ",
      timestamp: 1,
    };

    connection.sendText(message);

    expect(sent.mock.calls).toEqual([
      [{ type: "scroll", paneId: 9, delta: 999999 }],
      [message],
    ]);
    expect(paneState.followTail).toBe(true);
  });
});
