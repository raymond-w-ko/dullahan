// Hyperlink handling for OSC 8 links

/** Allowed protocols for hyperlinks (security whitelist) */
const ALLOWED_PROTOCOLS = ["http:", "https:", "mailto:", "tel:"];

/**
 * Validate that a URL is safe to open.
 * Only allows http, https, mailto, and tel protocols.
 *
 * @param url - The URL to validate
 * @returns true if the URL is safe to open
 */
export function isValidHyperlinkUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return ALLOWED_PROTOCOLS.includes(parsed.protocol);
  } catch {
    // Invalid URL
    return false;
  }
}

/**
 * Handle a hyperlink click event.
 * Validates the URL and opens it in a new tab if valid.
 *
 * @param e - The mouse click event
 * @param url - The URL to open
 */
export function handleHyperlinkClick(e: MouseEvent, url: string): void {
  e.preventDefault();
  e.stopPropagation();

  if (isValidHyperlinkUrl(url)) {
    window.open(url, "_blank", "noopener,noreferrer");
  }
}
