// Consolidated settings state management for SettingsModal
// Eliminates boilerplate by providing a single state object and typed setter

import { useState, useCallback, useRef } from "preact/hooks";
import * as config from "../config";
import type { ConfigKey, ConfigSchema } from "../config";
import { debug } from "../debug";

// Settings managed by SettingsModal (subset of ConfigSchema)
export interface SettingsState {
  theme: string;
  spacing: "compact" | "comfortable";
  fontSize: number;
  fontFamily: string;
  fontStyle: string;
  fontFeature: string;
  lineHeight: number;
  cursorStyle: "block" | "bar" | "underline" | "block_hollow";
  cursorColor: string;
  cursorText: string;
  cursorOpacity: number;
  cursorBlink: "" | "true" | "false";
  bellFeatures: string;
  selectionClearOnCopy: boolean;
  mouseMove: boolean;
}

// Keys that require CSS reapplication after change
const CSS_KEYS = new Set<keyof SettingsState>([
  "spacing",
  "fontSize",
  "fontFamily",
  "fontStyle",
  "fontFeature",
  "lineHeight",
  "cursorOpacity",
]);

type SettingsKey = keyof SettingsState;

/**
 * Consolidated settings hook for SettingsModal.
 *
 * Provides:
 * - Single state object with all settings
 * - Type-safe setSetting function that handles state, config, and side effects
 *
 * Usage:
 *   const { settings, setSetting } = useSettings();
 *   <select value={settings.theme} onChange={(e) => setSetting("theme", e.currentTarget.value)}>
 */
export function useSettings() {
  const settingsLog = useRef(debug.category("config"));
  const [settings, setSettings] = useState<SettingsState>(() => ({
    theme: config.get("theme"),
    spacing: config.get("spacing"),
    fontSize: config.get("fontSize"),
    fontFamily: config.get("fontFamily"),
    fontStyle: config.get("fontStyle"),
    fontFeature: config.get("fontFeature"),
    lineHeight: config.get("lineHeight"),
    cursorStyle: config.get("cursorStyle"),
    cursorColor: config.get("cursorColor"),
    cursorText: config.get("cursorText"),
    cursorOpacity: config.get("cursorOpacity"),
    cursorBlink: config.get("cursorBlink"),
    bellFeatures: config.get("bellFeatures"),
    selectionClearOnCopy: config.get("selectionClearOnCopy"),
    mouseMove: config.get("mouseMove"),
  }));

  const setSetting = useCallback(
    <K extends SettingsKey>(key: K, value: SettingsState[K]) => {
      settingsLog.current.log(`UI ${String(key)}=${String(value)}`);
      // Update local state
      setSettings((prev) => ({ ...prev, [key]: value }));

      // Persist to config (type assertion needed for cross-interface assignment)
      config.set(key as ConfigKey, value as ConfigSchema[ConfigKey]);

      // Handle side effects
      if (key === "theme") {
        document.querySelector(".app")?.setAttribute("data-theme", value as string);
      } else if (CSS_KEYS.has(key)) {
        config.applyToCSS();
      }
    },
    []
  );

  return { settings, setSetting };
}
