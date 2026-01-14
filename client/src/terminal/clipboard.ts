/**
 * Clipboard API wrapper for terminal copy/paste.
 *
 * Uses the modern Clipboard API (navigator.clipboard) which requires:
 * - Secure context (HTTPS or localhost)
 * - User gesture for paste (recent user interaction)
 *
 * Provides fallbacks and error handling for clipboard operations.
 */

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
    console.warn("Clipboard write failed:", err);
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
    console.warn("Clipboard read failed:", err);
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
    console.warn("Fallback copy failed:", err);
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
