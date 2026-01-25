/**
 * Wine-style category debug logging
 *
 * Syntax: ?debug=+all,-mouse,+pane or localStorage.setItem('debug', '+all,-mouse')
 *
 * Rules:
 * - +category enables a category
 * - -category disables a category
 * - +all / -all enables/disables all categories
 * - Evaluated left-to-right: +all,-mouse = everything except mouse
 * - Bare ?debug (no value) defaults to +all for backward compatibility
 *
 * Categories: connection, sync, snapshot, delta, mouse, mousemove, keyboard,
 *             keybind, clipboard, config, ime, resize, layout, store, shell
 */

/** All known debug categories */
export const DEBUG_CATEGORIES = [
  'connection',  // WebSocket connect/disconnect
  'sync',        // Delta sync, generation tracking
  'snapshot',    // Terminal state snapshots
  'delta',       // Delta updates
  'mouse',       // Mouse clicks, up/down, wheel
  'mousemove',   // Mouse move events (very spammy)
  'keyboard',    // Keyboard input
  'keybind',     // Keybind parsing
  'clipboard',   // Clipboard operations
  'config',      // Configuration
  'ime',         // IME composition
  'resize',      // Terminal resizing
  'layout',      // Layout messages
  'store',       // State store operations
  'shell',       // Shell integration (OSC 133)
] as const;

export type DebugCategory = (typeof DEBUG_CATEGORIES)[number];

interface DebugConfig {
  allEnabled: boolean;
  enabled: Set<string>;
  disabled: Set<string>;
  raw: string;
}

/**
 * Parse Wine-style debug config string
 * Examples: "+all,-mouse", "+mouse,+keyboard", "-all,+connection"
 */
function parseDebugConfig(value: string | null): DebugConfig {
  const config: DebugConfig = {
    allEnabled: false,
    enabled: new Set(),
    disabled: new Set(),
    raw: value ?? '',
  };

  // Bare ?debug or "true" means +all (backward compat)
  if (value === null || value === '' || value === 'true') {
    config.allEnabled = true;
    config.raw = '+all';
    return config;
  }

  // Parse comma-separated directives
  const parts = value.split(',').map((p) => p.trim()).filter((p) => p);

  for (const part of parts) {
    // Determine sign (+ or -)
    let sign = '+';
    let category = part;

    if (part.startsWith('+')) {
      sign = '+';
      category = part.slice(1);
    } else if (part.startsWith('-')) {
      sign = '-';
      category = part.slice(1);
    }

    // Handle special 'all' category
    if (category === 'all') {
      if (sign === '+') {
        config.allEnabled = true;
        config.disabled.clear(); // Reset specific disables
      } else {
        config.allEnabled = false;
        config.enabled.clear(); // Reset specific enables
      }
    } else {
      // Regular category
      if (sign === '+') {
        config.enabled.add(category);
        config.disabled.delete(category);
      } else {
        config.disabled.add(category);
        config.enabled.delete(category);
      }
    }
  }

  return config;
}

/** Load debug config from URL param or localStorage */
function loadDebugConfig(): DebugConfig {
  if (typeof window === 'undefined') {
    return { allEnabled: false, enabled: new Set(), disabled: new Set(), raw: '' };
  }

  // Check URL param first (highest priority)
  const urlParams = new URLSearchParams(window.location.search);
  if (urlParams.has('debug')) {
    const value = urlParams.get('debug');
    return parseDebugConfig(value);
  }

  // Check localStorage
  const stored = localStorage.getItem('debug');
  if (stored !== null) {
    return parseDebugConfig(stored);
  }

  // Disabled by default
  return { allEnabled: false, enabled: new Set(), disabled: new Set(), raw: '' };
}

// Current debug configuration (mutable for runtime changes)
let debugConfig = loadDebugConfig();

/** Check if any debug logging is enabled */
export function isDebug(): boolean {
  return debugConfig.allEnabled || debugConfig.enabled.size > 0;
}

/** Check if a specific category is enabled */
export function isCategoryEnabled(category: string): boolean {
  // Explicit disable always wins
  if (debugConfig.disabled.has(category)) return false;
  // Explicit enable
  if (debugConfig.enabled.has(category)) return true;
  // Fall back to all
  return debugConfig.allEnabled;
}

/** Get current debug config string */
export function getDebugConfig(): string {
  return debugConfig.raw;
}

/** Set debug config at runtime */
export function setDebugConfig(config: string): void {
  // Handle explicit disable
  if (config === '' || config === 'false') {
    debugConfig = { allEnabled: false, enabled: new Set(), disabled: new Set(), raw: '' };
    localStorage.removeItem('debug');
  } else {
    debugConfig = parseDebugConfig(config);
    localStorage.setItem('debug', config);
  }
  logDebugStatus();
}

/** Enable or disable all debug logging (backward compat) */
export function setDebug(enabled: boolean): void {
  setDebugConfig(enabled ? '+all' : '');
}

/** List all known categories */
export function listCategories(): readonly string[] {
  return DEBUG_CATEGORIES;
}

/** Get currently enabled categories */
export function getEnabledCategories(): string[] {
  if (debugConfig.allEnabled) {
    // All except disabled
    return DEBUG_CATEGORIES.filter((c) => !debugConfig.disabled.has(c));
  }
  // Only explicitly enabled
  return [...debugConfig.enabled];
}

/** Category-scoped logger interface */
export interface CategoryLogger {
  log: (...args: unknown[]) => void;
  warn: (...args: unknown[]) => void;
  error: (...args: unknown[]) => void;
  group: (...args: unknown[]) => void;
  groupEnd: () => void;
  table: (data: unknown) => void;
  time: (label: string) => void;
  timeEnd: (label: string) => void;
}

/** Create a category-scoped logger */
export function category(name: string): CategoryLogger {
  const prefix = `[dullahan:${name}]`;
  return {
    log: (...args: unknown[]) => {
      if (isCategoryEnabled(name)) console.log(prefix, ...args);
    },
    warn: (...args: unknown[]) => {
      if (isCategoryEnabled(name)) console.warn(prefix, ...args);
    },
    error: (...args: unknown[]) => {
      // Always log errors regardless of category
      console.error(prefix, ...args);
    },
    group: (...args: unknown[]) => {
      if (isCategoryEnabled(name)) console.group(prefix, ...args);
    },
    groupEnd: () => {
      if (isCategoryEnabled(name)) console.groupEnd();
    },
    table: (data: unknown) => {
      if (isCategoryEnabled(name)) console.table(data);
    },
    time: (label: string) => {
      if (isCategoryEnabled(name)) console.time(`${prefix} ${label}`);
    },
    timeEnd: (label: string) => {
      if (isCategoryEnabled(name)) console.timeEnd(`${prefix} ${label}`);
    },
  };
}

// Default logger (uncategorized, for backward compat)
export const debug = {
  log: (...args: unknown[]) => {
    if (isDebug()) console.log('[dullahan]', ...args);
  },
  warn: (...args: unknown[]) => {
    if (isDebug()) console.warn('[dullahan]', ...args);
  },
  error: (...args: unknown[]) => {
    // Always log errors
    console.error('[dullahan]', ...args);
  },
  group: (...args: unknown[]) => {
    if (isDebug()) console.group(...args);
  },
  groupEnd: () => {
    if (isDebug()) console.groupEnd();
  },
  table: (data: unknown) => {
    if (isDebug()) console.table(data);
  },
  time: (label: string) => {
    if (isDebug()) console.time(label);
  },
  timeEnd: (label: string) => {
    if (isDebug()) console.timeEnd(label);
  },
  // Category factory
  category,
};

// Export for backwards compatibility
export const DEBUG = isDebug();

/** Log current debug status */
function logDebugStatus(): void {
  if (isDebug()) {
    const enabled = getEnabledCategories();
    console.log(`[dullahan] Debug enabled: ${debugConfig.raw || '+all'}`);
    console.log(`[dullahan] Active categories: ${enabled.join(', ') || '(none)'}`);
    console.log(`[dullahan] All categories: ${DEBUG_CATEGORIES.join(', ')}`);
    console.log(`[dullahan] Change via: ?debug=+all,-mouse or setDebugConfig('+all,-mouse')`);
  } else {
    console.log('[dullahan] Debug disabled. Enable: ?debug or setDebugConfig("+all")');
  }
}

// Log status on load
logDebugStatus();
