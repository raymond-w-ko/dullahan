/**
 * Terminal Actions
 *
 * Defines action types for terminal keybinds. Actions are client-side
 * operations that can be triggered by key combinations, distinct from
 * sending key input to the server.
 *
 * The action system is designed to be extensible - new actions can be
 * added by extending the TerminalAction type and implementing a handler.
 */

// ============================================================================
// Action Types
// ============================================================================

/** Copy the current selection to clipboard */
export interface CopyAction {
  type: "copy_to_clipboard";
}

/** Paste from clipboard into the terminal */
export interface PasteAction {
  type: "paste_from_clipboard";
}

/** Scroll the terminal viewport */
export interface ScrollAction {
  type: "scroll";
  direction: "up" | "down";
  amount: "line" | "page" | "half_page" | "top" | "bottom";
}

/** Send literal text to the terminal (as if typed) */
export interface SendTextAction {
  type: "send_text";
  text: string;
}

/** Clear the terminal screen (like Ctrl+L) */
export interface ClearScreenAction {
  type: "clear_screen";
}

/** Reset the terminal to initial state */
export interface ResetTerminalAction {
  type: "reset_terminal";
}

/** Create a new window */
export interface NewWindowAction {
  type: "new_window";
}

/** Close the current window (future) */
export interface CloseWindowAction {
  type: "close_window";
}

/** Switch to a specific window by index (1-based) */
export interface SwitchWindowAction {
  type: "switch_window";
  windowIndex: number;
}

/** Cycle to next/previous window */
export interface CycleWindowAction {
  type: "cycle_window";
  direction: "next" | "prev";
}

/** Focus a specific pane within current window */
export interface FocusPaneAction {
  type: "focus_pane";
  direction: "up" | "down" | "left" | "right" | "next" | "prev";
}

/** Toggle fullscreen for the current pane */
export interface ToggleFullscreenAction {
  type: "toggle_fullscreen";
}

/** Open the settings modal */
export interface OpenSettingsAction {
  type: "open_settings";
}

/** Select all content in the terminal */
export interface SelectAllAction {
  type: "select_all";
}

/** Clear the current selection */
export interface ClearSelectionAction {
  type: "clear_selection";
}

/** No-op action (for unmapped keys) */
export interface NoOpAction {
  type: "none";
}

/** Union of all terminal actions */
export type TerminalAction =
  | CopyAction
  | PasteAction
  | ScrollAction
  | SendTextAction
  | ClearScreenAction
  | ResetTerminalAction
  | NewWindowAction
  | CloseWindowAction
  | SwitchWindowAction
  | CycleWindowAction
  | FocusPaneAction
  | ToggleFullscreenAction
  | OpenSettingsAction
  | SelectAllAction
  | ClearSelectionAction
  | NoOpAction;

// ============================================================================
// Action Context
// ============================================================================

/**
 * Context passed to action handlers, providing access to terminal state
 * and operations without tight coupling to specific implementations.
 */
export interface ActionContext {
  /** Current pane ID */
  paneId: number;

  /** Send text to the server (as keyboard input) */
  sendText: (text: string) => void;

  /** Send scroll command to server */
  sendScroll: (paneId: number, lines: number) => void;

  /** Get current selection text (if any) */
  getSelection: () => string | null;

  /** Read from clipboard */
  readClipboard: () => Promise<string>;

  /** Write to clipboard */
  writeClipboard: (text: string) => Promise<void>;

  /** Switch to a window by ID */
  switchWindow: (windowId: number) => void;

  /** Get window IDs in order */
  getWindowIds: () => number[];

  /** Get active window ID */
  getActiveWindowId: () => number;

  /** Create a new window */
  createWindow: () => void;

  /** Close a window by ID */
  closeWindow: (windowId: number) => void;

  /** Open settings modal */
  openSettings: () => void;

  /** Set focused pane */
  setFocusedPane: (paneId: number) => void;

  /** Get pane IDs for current window */
  getPaneIds: () => number[];

  /** Get focused pane ID */
  getFocusedPaneId: () => number;

  /** Toggle fullscreen for a pane */
  toggleFullscreen: (paneId: number) => void;

  /** Select all content in a pane */
  selectAll: (paneId: number) => void;

  /** Clear selection in a pane */
  clearSelectionInPane: (paneId: number) => void;
}

// ============================================================================
// Action Handler
// ============================================================================

/** Handler function type for executing an action */
export type ActionHandler = (
  action: TerminalAction,
  ctx: ActionContext
) => void | Promise<void>;

// ============================================================================
// Action Execution
// ============================================================================

/**
 * Check if an action can be performed in the current context.
 *
 * Used by the `performable:` keybind prefix - if this returns false,
 * the keybind is not consumed and the key passes through to the terminal.
 *
 * @example
 * // performable:ctrl+c=copy_to_clipboard
 * // Only consumes Ctrl+C if there's a selection to copy
 */
export function canPerformAction(
  action: TerminalAction,
  ctx: ActionContext
): boolean {
  switch (action.type) {
    case "copy_to_clipboard": {
      // Can only copy if there's a selection
      const selection = ctx.getSelection();
      return selection !== null && selection.length > 0;
    }

    case "switch_window": {
      // Can only switch if target window exists
      const windowIds = ctx.getWindowIds();
      const idx = action.windowIndex - 1;
      return idx >= 0 && idx < windowIds.length;
    }

    case "cycle_window": {
      // Can only cycle if there are multiple windows
      return ctx.getWindowIds().length > 1;
    }

    case "focus_pane": {
      // Can only focus if there are multiple panes
      return ctx.getPaneIds().length > 1;
    }

    // Most actions are always performable
    case "paste_from_clipboard":
    case "scroll":
    case "send_text":
    case "clear_screen":
    case "reset_terminal":
    case "new_window":
    case "close_window":
    case "toggle_fullscreen":
    case "open_settings":
    case "select_all":
    case "clear_selection":
    case "none":
      return true;
  }
}

/**
 * Execute a terminal action.
 *
 * This is the main entry point for the action system. It dispatches
 * the action to the appropriate handler based on the action type.
 */
export async function executeAction(
  action: TerminalAction,
  ctx: ActionContext
): Promise<void> {
  switch (action.type) {
    case "copy_to_clipboard":
      await handleCopy(ctx);
      break;

    case "paste_from_clipboard":
      await handlePaste(ctx);
      break;

    case "scroll":
      handleScroll(action, ctx);
      break;

    case "send_text":
      ctx.sendText(action.text);
      break;

    case "clear_screen":
      // Send Ctrl+L (form feed) to clear screen
      ctx.sendText("\x0c");
      break;

    case "reset_terminal":
      // Send ESC c (RIS - Reset to Initial State)
      ctx.sendText("\x1bc");
      break;

    case "new_window":
      ctx.createWindow();
      break;

    case "close_window":
      ctx.closeWindow(ctx.getActiveWindowId());
      break;

    case "switch_window":
      handleSwitchWindow(action, ctx);
      break;

    case "cycle_window":
      handleCycleWindow(action, ctx);
      break;

    case "focus_pane":
      handleFocusPane(action, ctx);
      break;

    case "toggle_fullscreen":
      ctx.toggleFullscreen(ctx.paneId);
      break;

    case "open_settings":
      ctx.openSettings();
      break;

    case "select_all":
      ctx.selectAll(ctx.paneId);
      break;

    case "clear_selection":
      ctx.clearSelectionInPane(ctx.paneId);
      break;

    case "none":
      // No-op
      break;
  }
}

// ============================================================================
// Individual Action Handlers
// ============================================================================

async function handleCopy(ctx: ActionContext): Promise<void> {
  const selection = ctx.getSelection();
  if (selection) {
    await ctx.writeClipboard(selection);
  }
}

async function handlePaste(ctx: ActionContext): Promise<void> {
  const text = await ctx.readClipboard();
  if (text) {
    ctx.sendText(text);
  }
}

function handleScroll(action: ScrollAction, ctx: ActionContext): void {
  let lines: number;

  switch (action.amount) {
    case "line":
      lines = action.direction === "up" ? -1 : 1;
      break;
    case "half_page":
      // Assume ~12 lines for half page (24 row terminal)
      lines = action.direction === "up" ? -12 : 12;
      break;
    case "page":
      // Assume ~24 lines for full page
      lines = action.direction === "up" ? -24 : 24;
      break;
    case "top":
      lines = -999999; // Scroll to very top
      break;
    case "bottom":
      lines = 999999; // Scroll to very bottom
      break;
  }

  ctx.sendScroll(ctx.paneId, lines);
}

function handleSwitchWindow(
  action: SwitchWindowAction,
  ctx: ActionContext
): void {
  const windowIds = ctx.getWindowIds();
  // windowIndex is 1-based, convert to 0-based array index
  const idx = action.windowIndex - 1;
  const targetId = windowIds[idx];
  if (idx >= 0 && idx < windowIds.length && targetId !== undefined) {
    ctx.switchWindow(targetId);
  }
}

function handleCycleWindow(
  action: CycleWindowAction,
  ctx: ActionContext
): void {
  const windowIds = ctx.getWindowIds();
  if (windowIds.length <= 1) return;

  const activeId = ctx.getActiveWindowId();
  const currentIdx = windowIds.indexOf(activeId);
  if (currentIdx === -1) return;

  let nextIdx: number;
  if (action.direction === "next") {
    nextIdx = (currentIdx + 1) % windowIds.length;
  } else {
    nextIdx = (currentIdx - 1 + windowIds.length) % windowIds.length;
  }

  const targetId = windowIds[nextIdx];
  if (targetId !== undefined) {
    ctx.switchWindow(targetId);
  }
}

function handleFocusPane(action: FocusPaneAction, ctx: ActionContext): void {
  const paneIds = ctx.getPaneIds();
  if (paneIds.length <= 1) return;

  const focusedId = ctx.getFocusedPaneId();
  const currentIdx = paneIds.indexOf(focusedId);
  if (currentIdx === -1) return;

  let nextIdx: number;
  if (action.direction === "next") {
    nextIdx = (currentIdx + 1) % paneIds.length;
  } else if (action.direction === "prev") {
    nextIdx = (currentIdx - 1 + paneIds.length) % paneIds.length;
  } else {
    // Directional focus (up/down/left/right) needs layout awareness
    // For now, just cycle
    nextIdx = (currentIdx + 1) % paneIds.length;
  }

  const targetId = paneIds[nextIdx];
  if (targetId !== undefined) {
    ctx.setFocusedPane(targetId);
  }
}

// ============================================================================
// Action Creators (convenience functions)
// ============================================================================

export const actions = {
  copy: (): CopyAction => ({ type: "copy_to_clipboard" }),
  paste: (): PasteAction => ({ type: "paste_from_clipboard" }),

  scrollUp: (amount: ScrollAction["amount"] = "line"): ScrollAction => ({
    type: "scroll",
    direction: "up",
    amount,
  }),
  scrollDown: (amount: ScrollAction["amount"] = "line"): ScrollAction => ({
    type: "scroll",
    direction: "down",
    amount,
  }),
  scrollToTop: (): ScrollAction => ({
    type: "scroll",
    direction: "up",
    amount: "top",
  }),
  scrollToBottom: (): ScrollAction => ({
    type: "scroll",
    direction: "down",
    amount: "bottom",
  }),

  sendText: (text: string): SendTextAction => ({ type: "send_text", text }),
  clearScreen: (): ClearScreenAction => ({ type: "clear_screen" }),
  resetTerminal: (): ResetTerminalAction => ({ type: "reset_terminal" }),

  newWindow: (): NewWindowAction => ({ type: "new_window" }),
  closeWindow: (): CloseWindowAction => ({ type: "close_window" }),
  switchWindow: (index: number): SwitchWindowAction => ({
    type: "switch_window",
    windowIndex: index,
  }),
  nextWindow: (): CycleWindowAction => ({
    type: "cycle_window",
    direction: "next",
  }),
  prevWindow: (): CycleWindowAction => ({
    type: "cycle_window",
    direction: "prev",
  }),

  focusPane: (direction: FocusPaneAction["direction"]): FocusPaneAction => ({
    type: "focus_pane",
    direction,
  }),
  nextPane: (): FocusPaneAction => ({ type: "focus_pane", direction: "next" }),
  prevPane: (): FocusPaneAction => ({ type: "focus_pane", direction: "prev" }),

  toggleFullscreen: (): ToggleFullscreenAction => ({
    type: "toggle_fullscreen",
  }),
  openSettings: (): OpenSettingsAction => ({ type: "open_settings" }),
  selectAll: (): SelectAllAction => ({ type: "select_all" }),
  clearSelection: (): ClearSelectionAction => ({ type: "clear_selection" }),
  none: (): NoOpAction => ({ type: "none" }),
};
