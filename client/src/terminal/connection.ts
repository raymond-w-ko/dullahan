// WebSocket connection to dullahan server

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
  content: string;
}

export type ServerMessage =
  | { type: "snapshot"; data: TerminalSnapshot }
  | { type: "output"; data: string }
  | { type: "pong" };

export type ClientMessage =
  | { type: "input"; data: string }
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
        this.onSnapshot?.(msg.data);
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

  sendInput(data: string): void {
    this.send({ type: "input", data });
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
