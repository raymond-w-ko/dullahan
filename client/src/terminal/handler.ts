/**
 * Common interface for terminal input handlers.
 *
 * All input handlers (keyboard, mouse, IME) share this base contract:
 * - attach/detach lifecycle for DOM element binding
 * - paneId for routing input to the correct terminal pane
 *
 * Each handler has a specific callback type for its input events.
 */

/**
 * Base interface for terminal input handlers.
 *
 * @typeParam TCallback - The callback function type for this handler's events
 */
export interface InputHandler<TCallback> {
  /**
   * Attach handler to a DOM element with callback for events.
   * Calls detach() first to clean up any previous attachment.
   */
  attach(element: HTMLElement, callback: TCallback): void;

  /**
   * Detach handler from DOM element and clean up event listeners.
   * Safe to call multiple times.
   */
  detach(): void;

  /**
   * Set the target pane ID for input events.
   * All events from this handler will be tagged with this pane ID.
   */
  setPaneId(paneId: number): void;

  /**
   * Get the current target pane ID.
   */
  readonly paneId: number;
}
