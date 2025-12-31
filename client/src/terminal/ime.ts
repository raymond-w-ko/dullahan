/**
 * IME (Input Method Editor) input handler for terminal
 * 
 * Stub implementation for composed text input (CJK, emoji, etc.)
 * Sends final composed text as UTF-8 to server.
 * 
 * TODO(du-???): Full IME support with composition events
 * - compositionstart: show composition UI
 * - compositionupdate: update preview
 * - compositionend: send final text
 * 
 * For now, just provides a method to send composed text for testing.
 */

export interface TextMessage {
  type: 'text';
  data: string;       // UTF-8 composed text
  timestamp: number;  // High-resolution timestamp
}

export type TextCallback = (message: TextMessage) => void;

export class IMEHandler {
  private callback: TextCallback | null = null;

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
   * Send composed text to terminal
   * Call this with final composed text from IME
   */
  sendText(text: string): void {
    if (!this.callback) return;
    if (text.length === 0) return;

    const message: TextMessage = {
      type: 'text',
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
