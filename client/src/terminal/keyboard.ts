/**
 * Keyboard input handler for terminal
 *
 * Captures keyboard events with full fidelity (1:1 with browser KeyboardEvent)
 * for server-side processing. Server converts to byte sequences.
 *
 * Design note: Full event data sent to server to support Kitty keyboard protocol
 * which requires modifier state, key release events, and distinguishes between
 * physical keys (code) and logical keys (key).
 *
 * Timestamps included for future ML-based keystroke dynamics analysis.
 *
 * Keybind Interception:
 * - Keybinds are checked before sending to server
 * - Matched keybinds execute client-side actions and consume the input
 * - Consumed keys are tracked so their keyup events are also suppressed
 * - Modifier-only events (Ctrl, Alt, etc.) always pass through to maintain
 *   accurate modifier state on the server for Kitty protocol
 */

import type { Keybind } from "./keybinds";
import { matchesKeybind } from "./keybinds";
import type { TerminalAction, ActionContext } from "./actions";
import { executeAction, canPerformAction } from "./actions";

export interface KeyMessage {
  type: "key";
  paneId: number; // Target pane ID
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

export type KeyboardCallback = (message: KeyMessage) => void;

/** A keybind paired with its action */
export interface KeybindEntry {
  keybind: Keybind;
  action: TerminalAction;
  /** If true, only consume the key if the action can be performed */
  performable?: boolean;
}

/**
 * Check if a key code represents a modifier-only key.
 * Modifier events should always pass through to the server.
 */
function isModifierKey(code: string): boolean {
  return (
    code === "ControlLeft" ||
    code === "ControlRight" ||
    code === "ShiftLeft" ||
    code === "ShiftRight" ||
    code === "AltLeft" ||
    code === "AltRight" ||
    code === "MetaLeft" ||
    code === "MetaRight" ||
    code === "CapsLock" ||
    code === "NumLock"
  );
}

export class KeyboardHandler {
  private element: HTMLElement | null = null;
  private callback: KeyboardCallback | null = null;
  private boundKeyDown: (e: KeyboardEvent) => void;
  private boundKeyUp: (e: KeyboardEvent) => void;
  private _paneId: number = 1; // Default pane ID

  // Keybind interception state
  private keybinds: KeybindEntry[] = [];
  private actionContext: ActionContext | null = null;
  private consumedKeys: Set<string> = new Set(); // Track consumed key codes

  constructor() {
    this.boundKeyDown = this.handleKeyDown.bind(this);
    this.boundKeyUp = this.handleKeyUp.bind(this);
  }

  /**
   * Set the target pane ID for keyboard events
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
   * Set the keybinds to intercept.
   * Call this when keybind configuration changes.
   */
  setKeybinds(bindings: KeybindEntry[]): void {
    this.keybinds = bindings;
  }

  /**
   * Set the action context for executing keybind actions.
   * Must be set before keybinds will work.
   */
  setActionContext(ctx: ActionContext): void {
    this.actionContext = ctx;
  }

  /**
   * Clear consumed keys. Call this on focus loss to reset state.
   */
  clearConsumedKeys(): void {
    this.consumedKeys.clear();
  }

  /**
   * Attach keyboard handler to an element
   * Element should have tabIndex set for focus
   */
  attach(element: HTMLElement, callback: KeyboardCallback): void {
    this.detach(); // Clean up any previous attachment

    this.element = element;
    this.callback = callback;

    // Ensure element is focusable
    if (!element.hasAttribute("tabindex")) {
      element.setAttribute("tabindex", "0");
    }

    element.addEventListener("keydown", this.boundKeyDown);
    element.addEventListener("keyup", this.boundKeyUp);

    // Clear consumed keys on blur to avoid stuck state
    element.addEventListener("blur", () => this.clearConsumedKeys());
  }

  /**
   * Detach keyboard handler
   */
  detach(): void {
    if (this.element) {
      this.element.removeEventListener("keydown", this.boundKeyDown);
      this.element.removeEventListener("keyup", this.boundKeyUp);
      this.element = null;
    }
    this.callback = null;
    this.consumedKeys.clear();
  }

  /**
   * Focus the attached element
   */
  focus(): void {
    this.element?.focus();
  }

  /**
   * Check if element is focused
   */
  isFocused(): boolean {
    return this.element !== null && document.activeElement === this.element;
  }

  /**
   * Find a matching keybind for the given event.
   * Returns the entry if found, null otherwise.
   *
   * If a keybind has `performable: true`, it's only matched if the action
   * can actually be performed (checked via canPerformAction).
   */
  private findMatchingKeybind(e: KeyboardEvent): KeybindEntry | null {
    for (const entry of this.keybinds) {
      if (matchesKeybind(e, entry.keybind)) {
        // If performable flag is set, check if action can be performed
        if (entry.performable && this.actionContext) {
          if (!canPerformAction(entry.action, this.actionContext)) {
            // Action can't be performed, skip this keybind
            continue;
          }
        }
        return entry;
      }
    }
    return null;
  }

  private handleKeyDown(e: KeyboardEvent): void {
    // Skip events during IME composition - let IME handle them
    if (e.isComposing) {
      return;
    }

    // Modifier-only keys always pass through to server
    // This maintains accurate modifier state for Kitty protocol
    if (isModifierKey(e.code)) {
      e.preventDefault();
      e.stopPropagation();
      this.sendKey(e, "down");
      return;
    }

    // Check for matching keybind
    const entry = this.findMatchingKeybind(e);
    if (entry && entry.action.type !== "none" && this.actionContext) {
      // For clipboard actions, don't preventDefault() to preserve user gesture
      // context required by the Clipboard API
      const isClipboardAction =
        entry.action.type === "copy_to_clipboard" ||
        entry.action.type === "paste_from_clipboard";

      if (!isClipboardAction) {
        e.preventDefault();
        e.stopPropagation();
      }

      // Track this key as consumed so we suppress its keyup
      this.consumedKeys.add(e.code);

      // Execute the action
      void executeAction(entry.action, this.actionContext);
      return;
    }

    // Legacy: Allow browser copy shortcut when there's a selection
    // This is a fallback before keybinds are configured
    const hasSelection = window.getSelection()?.toString();
    const isCopyShortcut =
      (e.metaKey && e.key === "c") || (e.ctrlKey && e.shiftKey && e.key === "C");
    if (hasSelection && isCopyShortcut) {
      // Let browser handle copy
      return;
    }

    e.preventDefault();
    e.stopPropagation();
    this.sendKey(e, "down");
  }

  private handleKeyUp(e: KeyboardEvent): void {
    // Skip events during IME composition - let IME handle them
    if (e.isComposing) {
      return;
    }

    // Modifier-only keys always pass through
    if (isModifierKey(e.code)) {
      e.preventDefault();
      e.stopPropagation();
      this.sendKey(e, "up");
      return;
    }

    // If this key was consumed on keydown, suppress the keyup too
    if (this.consumedKeys.has(e.code)) {
      e.preventDefault();
      e.stopPropagation();
      this.consumedKeys.delete(e.code);
      return;
    }

    e.preventDefault();
    e.stopPropagation();
    this.sendKey(e, "up");
  }

  private sendKey(e: KeyboardEvent, state: "down" | "up"): void {
    if (!this.callback) return;

    const message: KeyMessage = {
      type: "key",
      paneId: this._paneId,
      key: e.key,
      code: e.code,
      keyCode: e.keyCode,
      state,
      ctrl: e.ctrlKey,
      alt: e.altKey,
      shift: e.shiftKey,
      meta: e.metaKey,
      repeat: e.repeat,
      timestamp: performance.now(),
    };

    this.callback(message);
  }
}

/**
 * Create a keyboard handler instance
 */
export function createKeyboardHandler(): KeyboardHandler {
  return new KeyboardHandler();
}
