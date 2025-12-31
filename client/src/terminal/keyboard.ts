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
 */

export interface KeyMessage {
  type: 'key';
  key: string;        // Logical key value ("a", "Enter", "ArrowUp")
  code: string;       // Physical key code ("KeyA", "Enter", "ArrowUp")
  keyCode: number;    // Legacy keyCode (deprecated but useful)
  state: 'down' | 'up';
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
  repeat: boolean;
  timestamp: number;  // High-resolution timestamp (performance.now())
}

export type KeyboardCallback = (message: KeyMessage) => void;

export class KeyboardHandler {
  private element: HTMLElement | null = null;
  private callback: KeyboardCallback | null = null;
  private boundKeyDown: (e: KeyboardEvent) => void;
  private boundKeyUp: (e: KeyboardEvent) => void;

  constructor() {
    this.boundKeyDown = this.handleKeyDown.bind(this);
    this.boundKeyUp = this.handleKeyUp.bind(this);
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
    if (!element.hasAttribute('tabindex')) {
      element.setAttribute('tabindex', '0');
    }
    
    element.addEventListener('keydown', this.boundKeyDown);
    element.addEventListener('keyup', this.boundKeyUp);
  }

  /**
   * Detach keyboard handler
   */
  detach(): void {
    if (this.element) {
      this.element.removeEventListener('keydown', this.boundKeyDown);
      this.element.removeEventListener('keyup', this.boundKeyUp);
      this.element = null;
    }
    this.callback = null;
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

  private handleKeyDown(e: KeyboardEvent): void {
    e.preventDefault();
    e.stopPropagation();
    this.sendKey(e, 'down');
  }

  private handleKeyUp(e: KeyboardEvent): void {
    e.preventDefault();
    e.stopPropagation();
    this.sendKey(e, 'up');
  }

  private sendKey(e: KeyboardEvent, state: 'down' | 'up'): void {
    if (!this.callback) return;

    const message: KeyMessage = {
      type: 'key',
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
