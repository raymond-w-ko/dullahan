/**
 * Debug logging utility - enable via localStorage or URL param
 *
 * Enable: localStorage.setItem('debug', 'true') or add ?debug to URL
 * Disable: localStorage.removeItem('debug')
 */

const isDebugEnabled = (): boolean => {
  if (typeof window === 'undefined') return false;

  // Check URL param first (highest priority)
  const urlParams = new URLSearchParams(window.location.search);
  if (urlParams.has('debug')) return true;

  // Check localStorage
  return localStorage.getItem('debug') === 'true';
};

// Mutable debug state - can be toggled at runtime
let debugEnabled = isDebugEnabled();

/** Check if debug logging is currently enabled */
export function isDebug(): boolean {
  return debugEnabled;
}

/** Enable or disable debug logging at runtime */
export function setDebug(enabled: boolean): void {
  debugEnabled = enabled;
  if (enabled) {
    localStorage.setItem('debug', 'true');
    console.log('[dullahan] Debug logging enabled');
  } else {
    localStorage.removeItem('debug');
    console.log('[dullahan] Debug logging disabled');
  }
}

// Conditional logger - checks debug state on each call
export const debug = {
  log: (...args: unknown[]) => {
    if (debugEnabled) console.log('[dullahan]', ...args);
  },
  warn: (...args: unknown[]) => {
    if (debugEnabled) console.warn('[dullahan]', ...args);
  },
  error: (...args: unknown[]) => {
    // Always log errors
    console.error('[dullahan]', ...args);
  },
  group: (...args: unknown[]) => {
    if (debugEnabled) console.group(...args);
  },
  groupEnd: () => {
    if (debugEnabled) console.groupEnd();
  },
  table: (data: unknown) => {
    if (debugEnabled) console.table(data);
  },
  time: (label: string) => {
    if (debugEnabled) console.time(label);
  },
  timeEnd: (label: string) => {
    if (debugEnabled) console.timeEnd(label);
  },
};

// Export for backwards compatibility
export const DEBUG = debugEnabled;

// Log debug status on load
if (debugEnabled) {
  console.log('[dullahan] Debug logging enabled. Toggle in Settings or: localStorage.removeItem("debug")');
} else {
  console.log('[dullahan] Debug logging disabled. Toggle in Settings or: localStorage.setItem("debug", "true")');
}
