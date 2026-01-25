/**
 * Mouse input handler for terminal
 *
 * Captures mouse events and converts them to terminal cell coordinates.
 * Currently outputs debug info; will be extended to send to server.
 */

import { debug } from "../debug";
import { getCellDimensions, getPadding } from "./dimensions";

const mouseLog = debug.category('mouse');
const mousemoveLog = debug.category('mousemove');
import { get as getConfig } from "../config";
import { isValidHyperlinkUrl } from "./hyperlink";
import type { MouseMessage } from "../../../protocol/schema/messages";
import type { InputHandler } from "./handler";

export type { MouseMessage };

export type MouseCallback = (message: MouseMessage) => void;

export class MouseHandler implements InputHandler<MouseCallback> {
  private element: HTMLElement | null = null;
  private callback: MouseCallback | null = null;
  private _paneId: number = 1;

  // Bound handlers for event listener cleanup
  private boundMouseDown: (e: MouseEvent) => void;
  private boundMouseUp: (e: MouseEvent) => void;
  private boundMouseMove: (e: MouseEvent) => void;
  private boundMouseLeave: (e: MouseEvent) => void;
  private boundWheel: (e: WheelEvent) => void;

  // Cell dimensions (cached, updated on attach and resize)
  private cellWidth: number = 0;
  private cellHeight: number = 0;
  private terminalPaddingX: number = 0;
  private terminalPaddingY: number = 0;

  // Motion tracking state
  private buttonsPressed: number = 0; // Bitmask of pressed buttons
  private lastMotionX: number = -1; // Last reported cell X (-1 = none)
  private lastMotionY: number = -1; // Last reported cell Y
  private motionThrottleId: number | null = null; // requestAnimationFrame ID
  private pendingMotionEvent: MouseEvent | null = null; // Pending motion to send

  // Focus target - element to focus after mouseup (e.g., IME textarea)
  private focusTarget: HTMLElement | null = null;

  // Click tracking for hyperlink support
  private mouseDownCell: { x: number; y: number } | null = null;

  // Hyperlink lookup callback - returns URL if cell has hyperlink
  private hyperlinkLookup: ((x: number, y: number) => string | undefined) | null = null;

  constructor() {
    this.boundMouseDown = this.handleMouseDown.bind(this);
    this.boundMouseUp = this.handleMouseUp.bind(this);
    this.boundMouseMove = this.handleMouseMove.bind(this);
    this.boundMouseLeave = this.handleMouseLeave.bind(this);
    this.boundWheel = this.handleWheel.bind(this);
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
    element.addEventListener("mousemove", this.boundMouseMove);
    element.addEventListener("mouseleave", this.boundMouseLeave);
    element.addEventListener("wheel", this.boundWheel, { passive: false });
  }

  /**
   * Detach mouse handler
   */
  detach(): void {
    if (this.element) {
      this.element.removeEventListener("mousedown", this.boundMouseDown);
      this.element.removeEventListener("mouseup", this.boundMouseUp);
      this.element.removeEventListener("mousemove", this.boundMouseMove);
      this.element.removeEventListener("mouseleave", this.boundMouseLeave);
      this.element.removeEventListener("wheel", this.boundWheel);
      this.element = null;
    }
    this.callback = null;
    this.buttonsPressed = 0;
    this.lastMotionX = -1;
    this.lastMotionY = -1;
    if (this.motionThrottleId !== null) {
      cancelAnimationFrame(this.motionThrottleId);
      this.motionThrottleId = null;
    }
    this.pendingMotionEvent = null;
    this.focusTarget = null;
    this.mouseDownCell = null;
    this.hyperlinkLookup = null;
  }

  /**
   * Set an element to focus after mouseup events.
   * This is used to restore focus to the IME textarea after mouse selection.
   */
  setFocusTarget(element: HTMLElement | null): void {
    this.focusTarget = element;
  }

  /**
   * Set the hyperlink lookup function.
   * Called on mouseup to check if clicked cell has a hyperlink.
   */
  setHyperlinkLookup(lookup: ((x: number, y: number) => string | undefined) | null): void {
    this.hyperlinkLookup = lookup;
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
      const dims = getCellDimensions(measure);
      this.cellWidth = dims.cellWidth;
      this.cellHeight = dims.cellHeight;
    }

    // Get terminal padding (for coordinate offset)
    const padding = getPadding(this.element);
    this.terminalPaddingX = padding.left;
    this.terminalPaddingY = padding.top;
  }

  /**
   * Convert mouse event coordinates to terminal cell and pixel coordinates
   */
  private getTerminalCoords(
    e: MouseEvent
  ): { x: number; y: number; px: number; py: number } | null {
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

    // Pixel coordinates (0-indexed, clamped to non-negative)
    // SGR-Pixels (mode 1016) uses pixel coordinates without the +1 offset
    // that cell-based modes use
    const px = Math.max(0, Math.floor(relX));
    const py = Math.max(0, Math.floor(relY));

    // Clamp cell coordinates to non-negative (clicks in padding return 0,0)
    return {
      x: Math.max(0, x),
      y: Math.max(0, y),
      px,
      py,
    };
  }

  private handleMouseDown(e: MouseEvent): void {
    const coords = this.getTerminalCoords(e);
    if (!coords) return;

    // Track button state for motion detection
    this.buttonsPressed |= 1 << e.button;

    // Track mousedown cell for hyperlink click detection (left button only)
    if (e.button === 0) {
      this.mouseDownCell = { x: coords.x, y: coords.y };
    }

    const message: MouseMessage = {
      type: "mouse",
      paneId: this._paneId,
      button: e.button,
      x: coords.x,
      y: coords.y,
      px: coords.px,
      py: coords.py,
      state: "down",
      ctrl: e.ctrlKey,
      alt: e.altKey,
      shift: e.shiftKey,
      meta: e.metaKey,
      timestamp: performance.now(),
    };

    // Debug output
    const buttonName = ["left", "middle", "right"][e.button] ?? `button${e.button}`;
    mouseLog.log(
      `pane=${this._paneId} ${buttonName} down at (${coords.x}, ${coords.y}) px=(${coords.px}, ${coords.py})` +
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

    // Clear button state
    this.buttonsPressed &= ~(1 << e.button);

    // Check for hyperlink click: left button, same cell as mousedown, no modifiers
    if (
      e.button === 0 &&
      this.mouseDownCell &&
      this.mouseDownCell.x === coords.x &&
      this.mouseDownCell.y === coords.y &&
      !e.ctrlKey &&
      !e.altKey &&
      !e.shiftKey &&
      !e.metaKey
    ) {
      const url = this.hyperlinkLookup?.(coords.x, coords.y);
      if (url && isValidHyperlinkUrl(url)) {
        mouseLog.log(`[mouse] hyperlink click at (${coords.x}, ${coords.y}): ${url}`);
        window.open(url, "_blank", "noopener,noreferrer");
        this.mouseDownCell = null;
        // Restore focus to IME textarea
        if (this.focusTarget) {
          this.focusTarget.focus();
        }
        return; // Don't send mouse event to server
      }
    }
    this.mouseDownCell = null;

    const message: MouseMessage = {
      type: "mouse",
      paneId: this._paneId,
      button: e.button,
      x: coords.x,
      y: coords.y,
      px: coords.px,
      py: coords.py,
      state: "up",
      ctrl: e.ctrlKey,
      alt: e.altKey,
      shift: e.shiftKey,
      meta: e.metaKey,
      timestamp: performance.now(),
    };

    // Debug output
    const buttonName = ["left", "middle", "right"][e.button] ?? `button${e.button}`;
    mouseLog.log(
      `pane=${this._paneId} ${buttonName} up at (${coords.x}, ${coords.y}) px=(${coords.px}, ${coords.py})` +
        (e.ctrlKey ? " +ctrl" : "") +
        (e.altKey ? " +alt" : "") +
        (e.shiftKey ? " +shift" : "") +
        (e.metaKey ? " +meta" : "")
    );

    this.callback?.(message);

    // Restore focus to the target element (e.g., IME textarea) after mouseup
    // This ensures keyboard input continues to work after mouse selection
    if (this.focusTarget) {
      this.focusTarget.focus();
    }
  }

  private handleMouseMove(e: MouseEvent): void {
    // Check if mouse move events are enabled (disabled by default to reduce WebSocket noise)
    if (!getConfig("mouseMove")) {
      return;
    }

    // Only send motion events when a button is pressed (drag)
    // Mode 1003 (any-event) wants all motion, but we can't know client-side
    // what mode the server has enabled, so we send all motion and let the
    // server filter based on terminal mode.
    // However, to reduce bandwidth, we only send when position changes.

    const coords = this.getTerminalCoords(e);
    if (!coords) return;

    // Skip if position hasn't changed by at least 1 cell
    if (coords.x === this.lastMotionX && coords.y === this.lastMotionY) {
      return;
    }

    // Store the event for throttled sending
    this.pendingMotionEvent = e;

    // Throttle using requestAnimationFrame (max ~60fps)
    if (this.motionThrottleId === null) {
      this.motionThrottleId = requestAnimationFrame(() => {
        this.motionThrottleId = null;
        this.sendPendingMotion();
      });
    }
  }

  private sendPendingMotion(): void {
    const e = this.pendingMotionEvent;
    if (!e) return;
    this.pendingMotionEvent = null;

    const coords = this.getTerminalCoords(e);
    if (!coords) return;

    // Double-check position changed (could have moved back during throttle)
    if (coords.x === this.lastMotionX && coords.y === this.lastMotionY) {
      return;
    }

    this.lastMotionX = coords.x;
    this.lastMotionY = coords.y;

    // Determine which button is being dragged (use lowest pressed button)
    // If no button pressed, use button 3 (motion without button per X10 spec)
    let button = 3; // No button
    if (this.buttonsPressed & 1) button = 0; // Left
    else if (this.buttonsPressed & 2) button = 1; // Middle
    else if (this.buttonsPressed & 4) button = 2; // Right

    const message: MouseMessage = {
      type: "mouse",
      paneId: this._paneId,
      button,
      x: coords.x,
      y: coords.y,
      px: coords.px,
      py: coords.py,
      state: "move",
      ctrl: e.ctrlKey,
      alt: e.altKey,
      shift: e.shiftKey,
      meta: e.metaKey,
      timestamp: performance.now(),
    };

    mousemoveLog.log(
      `pane=${this._paneId} move at (${coords.x}, ${coords.y}) px=(${coords.px}, ${coords.py})` +
        (this.buttonsPressed ? ` buttons=${this.buttonsPressed}` : "") +
        (e.ctrlKey ? " +ctrl" : "") +
        (e.altKey ? " +alt" : "") +
        (e.shiftKey ? " +shift" : "") +
        (e.metaKey ? " +meta" : "")
    );

    this.callback?.(message);
  }

  private handleMouseLeave(_e: MouseEvent): void {
    // Reset motion tracking when mouse leaves the terminal
    this.lastMotionX = -1;
    this.lastMotionY = -1;
    // Note: We don't clear buttonsPressed here because the button might
    // still be held down when re-entering the terminal
  }

  private handleWheel(e: WheelEvent): void {
    const coords = this.getTerminalCoords(e);
    if (!coords) return;

    // Prevent default scrolling behavior - the terminal handles scroll
    e.preventDefault();

    // Wheel button codes (same as X10/SGR mouse protocol):
    // 64 = scroll up, 65 = scroll down, 66 = scroll left, 67 = scroll right
    // deltaY: positive = scroll down, negative = scroll up
    // deltaX: positive = scroll right, negative = scroll left

    // Handle vertical scroll
    if (e.deltaY !== 0) {
      const button = e.deltaY < 0 ? 64 : 65; // up : down
      const message: MouseMessage = {
        type: "mouse",
        paneId: this._paneId,
        button,
        x: coords.x,
        y: coords.y,
        px: coords.px,
        py: coords.py,
        state: "down",
        ctrl: e.ctrlKey,
        alt: e.altKey,
        shift: e.shiftKey,
        meta: e.metaKey,
        timestamp: performance.now(),
      };

      mouseLog.log(
        `pane=${this._paneId} wheel ${e.deltaY < 0 ? "up" : "down"} at (${coords.x}, ${coords.y})` +
          (e.ctrlKey ? " +ctrl" : "") +
          (e.altKey ? " +alt" : "") +
          (e.shiftKey ? " +shift" : "") +
          (e.metaKey ? " +meta" : "")
      );

      this.callback?.(message);
    }

    // Handle horizontal scroll
    if (e.deltaX !== 0) {
      const button = e.deltaX < 0 ? 66 : 67; // left : right
      const message: MouseMessage = {
        type: "mouse",
        paneId: this._paneId,
        button,
        x: coords.x,
        y: coords.y,
        px: coords.px,
        py: coords.py,
        state: "down",
        ctrl: e.ctrlKey,
        alt: e.altKey,
        shift: e.shiftKey,
        meta: e.metaKey,
        timestamp: performance.now(),
      };

      mouseLog.log(
        `pane=${this._paneId} wheel ${e.deltaX < 0 ? "left" : "right"} at (${coords.x}, ${coords.y})` +
          (e.ctrlKey ? " +ctrl" : "") +
          (e.altKey ? " +alt" : "") +
          (e.shiftKey ? " +shift" : "") +
          (e.metaKey ? " +meta" : "")
      );

      this.callback?.(message);
    }
  }
}

/**
 * Create a mouse handler instance
 */
export function createMouseHandler(): MouseHandler {
  return new MouseHandler();
}
