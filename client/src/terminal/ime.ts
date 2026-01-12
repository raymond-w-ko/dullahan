/**
 * IME (Input Method Editor) input handler for terminal
 *
 * Handles composed text input (CJK, emoji, etc.) via a hidden textarea.
 * Uses the CompositionEvent API to track IME state and sends final
 * composed text as UTF-8 to the server.
 *
 * The hidden textarea approach is standard (used by xterm.js, etc.):
 * - textarea has opacity: 0 (NOT display: none - IME won't attach)
 * - Positioned near terminal for IME popup placement
 * - Also enables mobile virtual keyboard support
 */

export interface TextMessage {
  type: "text";
  paneId: number; // Target pane ID
  data: string; // UTF-8 composed text
  timestamp: number; // High-resolution timestamp
}

export type TextCallback = (message: TextMessage) => void;

export class IMEHandler {
  private callback: TextCallback | null = null;
  private _paneId: number = 1; // Default pane ID
  private textarea: HTMLTextAreaElement | null = null;
  private parent: HTMLElement | null = null;
  private _isComposing: boolean = false;

  // Bound event handlers for cleanup
  private boundCompositionStart: (e: CompositionEvent) => void;
  private boundCompositionUpdate: (e: CompositionEvent) => void;
  private boundCompositionEnd: (e: CompositionEvent) => void;
  private boundInput: (e: Event) => void;
  private boundKeyDown: (e: KeyboardEvent) => void;

  constructor() {
    this.boundCompositionStart = this.handleCompositionStart.bind(this);
    this.boundCompositionUpdate = this.handleCompositionUpdate.bind(this);
    this.boundCompositionEnd = this.handleCompositionEnd.bind(this);
    this.boundInput = this.handleInput.bind(this);
    this.boundKeyDown = this.handleKeyDown.bind(this);
  }

  /**
   * Set the target pane ID for text messages
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
   * Check if IME composition is currently in progress
   */
  get isComposing(): boolean {
    return this._isComposing;
  }

  /**
   * Set callback for text messages
   */
  setCallback(callback: TextCallback): void {
    this.callback = callback;
  }

  /**
   * Clear callback
   */
  clearCallback(): void {
    this.callback = null;
  }

  /**
   * Attach IME handler to a parent element.
   * Creates a hidden textarea for IME input.
   */
  attach(parent: HTMLElement): void {
    this.detach(); // Clean up any previous attachment

    this.parent = parent;

    // Create hidden textarea for IME input
    const textarea = document.createElement("textarea");
    textarea.className = "terminal-ime-input";
    textarea.setAttribute("autocomplete", "off");
    textarea.setAttribute("autocorrect", "off");
    textarea.setAttribute("autocapitalize", "off");
    textarea.setAttribute("spellcheck", "false");
    // Accessible name for screen readers
    textarea.setAttribute("aria-label", "Terminal input");

    // Attach event listeners
    textarea.addEventListener("compositionstart", this.boundCompositionStart);
    textarea.addEventListener("compositionupdate", this.boundCompositionUpdate);
    textarea.addEventListener("compositionend", this.boundCompositionEnd);
    textarea.addEventListener("input", this.boundInput);
    textarea.addEventListener("keydown", this.boundKeyDown);

    // Insert into DOM
    parent.appendChild(textarea);
    this.textarea = textarea;
  }

  /**
   * Detach IME handler and clean up
   */
  detach(): void {
    if (this.textarea) {
      this.textarea.removeEventListener(
        "compositionstart",
        this.boundCompositionStart
      );
      this.textarea.removeEventListener(
        "compositionupdate",
        this.boundCompositionUpdate
      );
      this.textarea.removeEventListener(
        "compositionend",
        this.boundCompositionEnd
      );
      this.textarea.removeEventListener("input", this.boundInput);
      this.textarea.removeEventListener("keydown", this.boundKeyDown);

      this.textarea.remove();
      this.textarea = null;
    }
    this.parent = null;
    this._isComposing = false;
  }

  /**
   * Focus the hidden textarea for IME input
   */
  focus(): void {
    this.textarea?.focus();
  }

  /**
   * Check if textarea is focused
   */
  isFocused(): boolean {
    return this.textarea !== null && document.activeElement === this.textarea;
  }

  /**
   * Get the textarea element for other handlers to attach to.
   * Returns null if not attached.
   */
  getElement(): HTMLTextAreaElement | null {
    return this.textarea;
  }

  /**
   * Handle composition start - IME begins building text
   */
  private handleCompositionStart(_e: CompositionEvent): void {
    this._isComposing = true;
  }

  /**
   * Handle composition update - candidate text is changing
   * Could optionally render inline at cursor in the future
   */
  private handleCompositionUpdate(_e: CompositionEvent): void {
    // Currently a no-op - could show preview in future
  }

  /**
   * Handle composition end - user committed final text
   */
  private handleCompositionEnd(e: CompositionEvent): void {
    this._isComposing = false;

    // The composed text is in e.data
    if (e.data) {
      this.sendText(e.data);
    }

    // Clear textarea after processing
    if (this.textarea) {
      this.textarea.value = "";
    }
  }

  /**
   * Handle input event - fires for non-IME text input (paste, direct input)
   * Also fires after composition but we handle that in compositionend
   */
  private handleInput(e: Event): void {
    // Skip if we're in the middle of composition
    if (this._isComposing) return;

    const target = e.target as HTMLTextAreaElement;
    const text = target.value;

    if (text) {
      this.sendText(text);
      // Clear after processing
      target.value = "";
    }
  }

  /**
   * Handle keydown on textarea - prevent default for most keys
   * to avoid double-handling with KeyboardHandler
   */
  private handleKeyDown(e: KeyboardEvent): void {
    // During composition, let IME handle everything
    if (this._isComposing || e.isComposing) {
      return;
    }

    // For normal keydown events on the textarea, we want to prevent
    // default behavior (like inserting text) since KeyboardHandler
    // on the parent element handles the actual key events.
    // Exception: allow paste (Ctrl+V / Cmd+V) to work
    const isPaste =
      (e.key === "v" || e.key === "V") && (e.ctrlKey || e.metaKey);
    if (!isPaste) {
      e.preventDefault();
    }
  }

  /**
   * Send composed text to terminal
   * Call this with final composed text from IME
   */
  sendText(text: string): void {
    if (!this.callback) return;
    if (text.length === 0) return;

    const message: TextMessage = {
      type: "text",
      paneId: this._paneId,
      data: text,
      timestamp: performance.now(),
    };

    this.callback(message);
  }
}

/**
 * Create an IME handler instance
 */
export function createIMEHandler(): IMEHandler {
  return new IMEHandler();
}
