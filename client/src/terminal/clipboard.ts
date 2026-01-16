/**
 * Clipboard API wrapper for terminal copy/paste.
 *
 * Uses the modern Clipboard API (navigator.clipboard) which requires:
 * - Secure context (HTTPS or localhost)
 * - User gesture for paste (recent user interaction)
 *
 * Provides fallbacks and error handling for clipboard operations.
 */

import { debug } from "../debug";
import { cellToChar } from "../../../protocol/schema/cell";
import type { Cell } from "../../../protocol/schema/cell";
import type { SelectionBounds } from "../../../protocol/schema/messages";

/**
 * Check if the Clipboard API is available.
 */
export function isClipboardAvailable(): boolean {
  return (
    typeof navigator !== "undefined" &&
    typeof navigator.clipboard !== "undefined" &&
    typeof navigator.clipboard.writeText === "function" &&
    typeof navigator.clipboard.readText === "function"
  );
}

/**
 * Copy text to the clipboard.
 *
 * @param text - The text to copy
 * @returns true if successful, false otherwise
 */
export async function copyToClipboard(text: string): Promise<boolean> {
  if (!text) {
    return false;
  }

  try {
    if (isClipboardAvailable()) {
      await navigator.clipboard.writeText(text);
      return true;
    }

    // Fallback: use deprecated execCommand (for older browsers)
    const success = fallbackCopy(text);
    if (!success) {
      window.alert("Copy failed: Clipboard API not available and fallback failed.");
    }
    return success;
  } catch (err) {
    debug.warn("Clipboard write failed:", err);
    // Try fallback on permission error
    const success = fallbackCopy(text);
    if (!success) {
      window.alert(`Copy failed: ${err instanceof Error ? err.message : "Unknown error"}`);
    }
    return success;
  }
}

/**
 * Read text from the clipboard.
 *
 * @returns The clipboard text, or empty string if unavailable/denied
 */
export async function pasteFromClipboard(): Promise<string> {
  try {
    if (isClipboardAvailable()) {
      return await navigator.clipboard.readText();
    }
    window.alert("Paste failed: Clipboard API not available.");
    return "";
  } catch (err) {
    // Permission denied or not in secure context
    debug.warn("Clipboard read failed:", err);
    window.alert(`Paste failed: ${err instanceof Error ? err.message : "Permission denied or not in secure context"}`);
    return "";
  }
}

/**
 * Fallback copy using deprecated execCommand.
 * Used when Clipboard API is unavailable or fails.
 */
function fallbackCopy(text: string): boolean {
  try {
    // Create a temporary textarea
    const textarea = document.createElement("textarea");
    textarea.value = text;

    // Make it invisible but part of the document
    textarea.style.position = "fixed";
    textarea.style.left = "-9999px";
    textarea.style.top = "-9999px";
    textarea.setAttribute("readonly", "");

    document.body.appendChild(textarea);
    textarea.select();

    // Execute copy command
    const success = document.execCommand("copy");

    document.body.removeChild(textarea);
    return success;
  } catch (err) {
    debug.warn("Fallback copy failed:", err);
    return false;
  }
}

/**
 * Get the current text selection from the document.
 *
 * @returns The selected text, or null if nothing is selected
 */
export function getSelection(): string | null {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed) {
    return null;
  }
  const text = selection.toString();
  return text || null;
}

/**
 * Clear the current text selection.
 */
export function clearSelection(): void {
  const selection = window.getSelection();
  if (selection) {
    selection.removeAllRanges();
  }
}

/**
 * Extract text from terminal cells within the given selection bounds.
 * Handles both normal (line) and rectangular selection modes.
 *
 * @param cells - Terminal cell array (row-major order)
 * @param cols - Number of columns in the terminal
 * @param selection - Selection bounds from server
 * @returns The selected text as a string
 */
export function getTerminalSelectionText(
  cells: Cell[],
  cols: number,
  selection: SelectionBounds
): string {
  // Normalize so start is before end
  let startX = selection.startX;
  let startY = selection.startY;
  let endX = selection.endX;
  let endY = selection.endY;

  // Swap if start is after end (for reversed selection)
  if (startY > endY || (startY === endY && startX > endX)) {
    [startX, endX] = [endX, startX];
    [startY, endY] = [endY, startY];
  }

  const lines: string[] = [];

  if (selection.isRectangle) {
    // Rectangle selection: extract fixed columns from each row
    const minX = Math.min(startX, endX);
    const maxX = Math.max(startX, endX);

    for (let y = startY; y <= endY; y++) {
      let line = "";
      for (let x = minX; x <= maxX; x++) {
        const idx = y * cols + x;
        const cell = cells[idx];
        line += cell ? cellToChar(cell) : " ";
      }
      lines.push(line.trimEnd());
    }
  } else {
    // Normal (line) selection
    for (let y = startY; y <= endY; y++) {
      let lineStart: number;
      let lineEnd: number;

      if (y === startY && y === endY) {
        // Single line: between start and end
        lineStart = startX;
        lineEnd = endX;
      } else if (y === startY) {
        // First line: from startX to end of line
        lineStart = startX;
        lineEnd = cols - 1;
      } else if (y === endY) {
        // Last line: from start of line to endX
        lineStart = 0;
        lineEnd = endX;
      } else {
        // Middle lines: entire line
        lineStart = 0;
        lineEnd = cols - 1;
      }

      let line = "";
      for (let x = lineStart; x <= lineEnd; x++) {
        const idx = y * cols + x;
        const cell = cells[idx];
        line += cell ? cellToChar(cell) : " ";
      }
      lines.push(line.trimEnd());
    }
  }

  return lines.join("\n");
}
