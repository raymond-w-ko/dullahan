/**
 * Client Configuration System
 *
 * Uses localStorage for persistence with get(key, fallback) pattern.
 * Never writes defaults - only stores user-changed values.
 */

import { debug } from "./debug";

// Type definitions for config values
export interface ConfigSchema {
  // Theme
  theme: string;
  
  // Layout
  spacing: 'compact' | 'comfortable';
  
  // Font settings
  fontFamily: string;
  fontSize: number;
  fontStyle: string;
  fontFeature: string;
  lineHeight: number;
  
  // Cell adjustments
  adjustCellWidth: number;
  adjustCellHeight: number;
  
  // Cursor
  cursorStyle: 'block' | 'bar' | 'underline' | 'block_hollow';
  cursorColor: string;  // '' = theme, 'cell-foreground', 'cell-background', or CSS color
  cursorText: string;   // '' = theme, 'cell-foreground', 'cell-background', or CSS color
  cursorBlink: '' | 'true' | 'false';  // '' = auto (respect DEC Mode 12)
  cursorOpacity: number;
  
  // Window
  windowWidth: number;
  windowHeight: number;
  
  // Selection
  selectionClearOnCopy: boolean;

  // Mouse
  mouseMove: boolean;  // Send mouse move events (filtered to cell-level changes)

  // Bell (matches ghostty's bell-features)
  // Comma-separated list: "audio", "attention", "title"
  bellFeatures: string;

  // Shell integration (OSC 133) logging
  // When enabled, logs shell integration events to the browser console
  shellIntegrationLogging: boolean;
}

// Default values - used when localStorage doesn't have a value
export const DEFAULTS: ConfigSchema = {
  // Theme
  theme: 'selenized-light',
  
  // Layout
  spacing: 'compact',
  
  // Font settings
  fontFamily: 'Iosevka, JetBrains Mono, Fira Code, SF Mono, Menlo, Monaco, Courier New, monospace',
  fontSize: 12,
  fontStyle: 'normal',
  fontFeature: '',
  lineHeight: 1.2,
  
  // Cell adjustments
  adjustCellWidth: 0,
  adjustCellHeight: 0,
  
  // Cursor
  cursorStyle: 'block',
  cursorColor: '',      // empty = use theme --term-cursor-bg
  cursorText: '',       // empty = use theme --term-cursor-fg
  cursorBlink: '',  // auto - respect DEC Mode 12
  cursorOpacity: 1.0,
  
  // Window
  windowWidth: 80,
  windowHeight: 24,
  
  // Selection
  selectionClearOnCopy: true,

  // Mouse
  mouseMove: true,  // Send mouse move events (already filtered to cell-level changes only)

  // Bell (all enabled by default, matches ghostty)
  bellFeatures: 'audio,attention,title',

  // Shell integration logging (disabled by default)
  // Enable via URL param: ?shell-integration-logging
  // Or localStorage: localStorage.setItem('dullahan.shellIntegrationLogging', 'true')
  shellIntegrationLogging: false,
};

export type ConfigKey = keyof ConfigSchema;
export type ConfigValue<K extends ConfigKey> = ConfigSchema[K];

/** Bell feature flags parsed from bellFeatures string */
export interface BellFeatureFlags {
  audio: boolean;
  attention: boolean;
  title: boolean;
}

/** Parse bellFeatures string into individual flags */
export function parseBellFeatures(features: string): BellFeatureFlags {
  const set = new Set(features.split(',').map(f => f.trim().toLowerCase()));
  return {
    audio: set.has('audio'),
    attention: set.has('attention'),
    title: set.has('title'),
  };
}

/** Get current bell feature flags */
export function getBellFeatures(): BellFeatureFlags {
  return parseBellFeatures(get('bellFeatures'));
}

const STORAGE_PREFIX = 'dullahan.';

/**
 * Get a config value, returning fallback if not set in localStorage
 */
export function get<K extends ConfigKey>(key: K, fallback?: ConfigValue<K>): ConfigValue<K> {
  const defaultValue = fallback ?? DEFAULTS[key];
  
  try {
    const stored = localStorage.getItem(STORAGE_PREFIX + key);
    if (stored === null) {
      return defaultValue;
    }
    
    // Parse based on the type of the default value
    const defaultType = typeof defaultValue;
    
    if (defaultType === 'number') {
      const num = parseFloat(stored);
      return (isNaN(num) ? defaultValue : num) as ConfigValue<K>;
    }
    
    if (defaultType === 'boolean') {
      return (stored === 'true') as ConfigValue<K>;
    }
    
    // String or other
    return stored as ConfigValue<K>;
  } catch {
    // localStorage might be unavailable (private mode, etc.)
    return defaultValue;
  }
}

/**
 * Set a config value in localStorage
 */
export function set<K extends ConfigKey>(key: K, value: ConfigValue<K>): void {
  try {
    localStorage.setItem(STORAGE_PREFIX + key, String(value));
    
    // Dispatch event so components can react to changes
    window.dispatchEvent(new CustomEvent('config-change', { 
      detail: { key, value } 
    }));
  } catch {
    // localStorage might be unavailable
    debug.warn(`Failed to save config: ${key}`);
  }
}

/**
 * Remove a config value (revert to default)
 */
export function remove(key: ConfigKey): void {
  try {
    localStorage.removeItem(STORAGE_PREFIX + key);
    
    window.dispatchEvent(new CustomEvent('config-change', { 
      detail: { key, value: DEFAULTS[key] } 
    }));
  } catch {
    debug.warn(`Failed to remove config: ${key}`);
  }
}

/**
 * Check if a value has been explicitly set (not using default)
 */
export function isSet(key: ConfigKey): boolean {
  try {
    return localStorage.getItem(STORAGE_PREFIX + key) !== null;
  } catch {
    return false;
  }
}

/**
 * Get all config values as an object
 */
export function getAll(): typeof DEFAULTS {
  const result = { ...DEFAULTS };
  
  for (const key of Object.keys(DEFAULTS) as ConfigKey[]) {
    (result as Record<string, unknown>)[key] = get(key);
  }
  
  return result;
}

/**
 * Apply config values to CSS variables
 */
export function applyToCSS(): void {
  const root = document.documentElement;
  
  // Spacing mode (data attribute for CSS selector)
  const spacing = get('spacing');
  if (spacing === 'comfortable') {
    root.dataset.spacing = 'comfortable';
  } else {
    delete root.dataset.spacing;
  }
  
  // Font settings
  root.style.setProperty('--term-font', get('fontFamily'));
  root.style.setProperty('--term-font-size', `${get('fontSize')}px`);
  root.style.setProperty('--term-font-weight', get('fontStyle'));
  root.style.setProperty('--term-font-feature', get('fontFeature') || 'normal');
  root.style.setProperty('--term-line-height', String(get('lineHeight')));
  
  // Cursor
  root.style.setProperty('--term-cursor-opacity', String(get('cursorOpacity')));
}

/**
 * Hook for listening to config changes
 */
export function onChange(callback: (key: ConfigKey, value: unknown) => void): () => void {
  const handler = (e: Event) => {
    const { key, value } = (e as CustomEvent).detail;
    callback(key, value);
  };
  
  window.addEventListener('config-change', handler);
  return () => window.removeEventListener('config-change', handler);
}
