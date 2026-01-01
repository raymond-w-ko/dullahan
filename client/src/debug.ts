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

// Cache the result at load time (can be toggled by reload)
export const DEBUG = isDebugEnabled();

// Conditional logger - no-op when debug is disabled
export const debug = {
  log: DEBUG ? console.log.bind(console, '[dullahan]') : () => {},
  warn: DEBUG ? console.warn.bind(console, '[dullahan]') : () => {},
  error: console.error.bind(console, '[dullahan]'), // Always log errors
  group: DEBUG ? console.group.bind(console) : () => {},
  groupEnd: DEBUG ? console.groupEnd.bind(console) : () => {},
  table: DEBUG ? console.table.bind(console) : () => {},
  time: DEBUG ? console.time.bind(console) : () => {},
  timeEnd: DEBUG ? console.timeEnd.bind(console) : () => {},
};

// Log debug status on load
if (DEBUG) {
  console.log('[dullahan] Debug logging enabled. Disable with: localStorage.removeItem("debug")');
} else {
  console.log('[dullahan] Debug logging disabled. Enable with: localStorage.setItem("debug", "true") or add ?debug to URL');
}
