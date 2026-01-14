/**
 * Mouse input handler for terminal
 *
 * Captures mouse events and converts them to terminal cell coordinates.
 * Currently outputs debug info; will be extended to send to server.
 */

import { debug } from "../debug";

export interface MouseMessage {
  type: "mouse";
  paneId: number;
  button: number; // 0=left, 1=middle, 2=right
  x: number; // Column (0-indexed)
  y: number; // Row (0-indexed)
  state: "down" | "up" | "move";
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
  timestamp: number;
}

export type MouseCallback = (message: MouseMessage) => void;

export class MouseHandler {
  private element: HTMLElement | null = null;
  private callback: MouseCallback | null = null;
  private _paneId: number = 1;

  // Bound handlers for event listener cleanup
  private boundMouseDown: (e: MouseEvent) => void;
  private boundMouseUp: (e: MouseEvent) => void;

  // Cell dimensions (cached, updated on attach and resize)
  private cellWidth: number = 0;
  private cellHeight: number = 0;
  private terminalPaddingX: number = 0;
  private terminalPaddingY: number = 0;

  constructor() {
    this.boundMouseDown = this.handleMouseDown.bind(this);
    this.boundMouseUp = this.handleMouseUp.bind(this);
  }

  /**
   * Set the target pane ID for mouse events
   */
  setPaneId(paneId: number): void {
    this._paneId = paneId;
  }

  /**
   * Get the current target pane ID
   */
  get paneId(): number {
    return this._paneId;
  }

  /**
   * Attach mouse handler to a terminal element.
   * The element should be the .terminal pre element that contains .terminal-measure.
   */
  attach(element: HTMLElement, callback: MouseCallback): void {
    this.detach(); // Clean up any previous attachment

    this.element = element;
    this.callback = callback;

    // Calculate initial cell dimensions
    this.updateCellDimensions();

    element.addEventListener("mousedown", this.boundMouseDown);
    element.addEventListener("mouseup", this.boundMouseUp);
  }

  /**
   * Detach mouse handler
   */
  detach(): void {
    if (this.element) {
      this.element.removeEventListener("mousedown", this.boundMouseDown);
      this.element.removeEventListener("mouseup", this.boundMouseUp);
      this.element = null;
    }
    this.callback = null;
  }

  /**
   * Update cached cell dimensions from the measurement element.
   * Call this when fonts load or terminal resizes.
   */
  updateCellDimensions(): void {
    if (!this.element) return;

    // Find the measurement element - it's in the parent container (.terminal-container),
    // not inside the .terminal element itself
    const container = this.element.parentElement;
    const measure = container?.querySelector(
      ".terminal-measure"
    ) as HTMLDivElement | null;
    if (measure) {
      const rect = measure.getBoundingClientRect();
      this.cellWidth = rect.width;
      this.cellHeight = rect.height;
    }

    // Get terminal padding
    const style = getComputedStyle(this.element);
    this.terminalPaddingX = parseFloat(style.paddingLeft);
    this.terminalPaddingY = parseFloat(style.paddingTop);
  }

  /**
   * Convert mouse event coordinates to terminal cell coordinates
   */
  private getTerminalCoords(e: MouseEvent): { x: number; y: number } | null {
    if (!this.element) return null;

    // Lazy update if dimensions not yet known
    if (this.cellWidth === 0 || this.cellHeight === 0) {
      this.updateCellDimensions();
      if (this.cellWidth === 0 || this.cellHeight === 0) {
        return null;
      }
    }

    const rect = this.element.getBoundingClientRect();

    // Mouse position relative to terminal content area (after padding)
    const relX = e.clientX - rect.left - this.terminalPaddingX;
    const relY = e.clientY - rect.top - this.terminalPaddingY;

    // Convert to cell coordinates
    const x = Math.floor(relX / this.cellWidth);
    const y = Math.floor(relY / this.cellHeight);

    // Clamp to non-negative (clicks in padding return 0,0)
    return {
      x: Math.max(0, x),
      y: Math.max(0, y),
    };
  }

  private handleMouseDown(e: MouseEvent): void {
    const coords = this.getTerminalCoords(e);
    if (!coords) return;

    const message: MouseMessage = {
      type: "mouse",
      paneId: this._paneId,
      button: e.button,
      x: coords.x,
      y: coords.y,
      state: "down",
      ctrl: e.ctrlKey,
      alt: e.altKey,
      shift: e.shiftKey,
      meta: e.metaKey,
      timestamp: performance.now(),
    };

    // Debug output
    const buttonName = ["left", "middle", "right"][e.button] ?? `button${e.button}`;
    debug.log(
      `[mouse] pane=${this._paneId} ${buttonName} down at (${coords.x}, ${coords.y})` +
        (e.ctrlKey ? " +ctrl" : "") +
        (e.altKey ? " +alt" : "") +
        (e.shiftKey ? " +shift" : "") +
        (e.metaKey ? " +meta" : "")
    );

    this.callback?.(message);
  }

  private handleMouseUp(e: MouseEvent): void {
    const coords = this.getTerminalCoords(e);
    if (!coords) return;

    const message: MouseMessage = {
      type: "mouse",
      paneId: this._paneId,
      button: e.button,
      x: coords.x,
      y: coords.y,
      state: "up",
      ctrl: e.ctrlKey,
      alt: e.altKey,
      shift: e.shiftKey,
      meta: e.metaKey,
      timestamp: performance.now(),
    };

    // Debug output
    const buttonName = ["left", "middle", "right"][e.button] ?? `button${e.button}`;
    debug.log(
      `[mouse] pane=${this._paneId} ${buttonName} up at (${coords.x}, ${coords.y})` +
        (e.ctrlKey ? " +ctrl" : "") +
        (e.altKey ? " +alt" : "") +
        (e.shiftKey ? " +shift" : "") +
        (e.metaKey ? " +meta" : "")
    );

    this.callback?.(message);
  }
}

/**
 * Create a mouse handler instance
 */
export function createMouseHandler(): MouseHandler {
  return new MouseHandler();
}
