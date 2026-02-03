import { h } from "preact";
import { useState, useEffect, useRef } from "preact/hooks";
import { useModalBehavior } from "../hooks/useModalBehavior";
import { useSettings } from "../hooks/useSettings";
import type { SettingsState } from "../hooks/useSettings";
import { THEMES } from "../themes";
import { isDebug, setDebug } from "../debug";
import { debug } from "../debug";

interface SettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export function SettingsModal({ isOpen, onClose }: SettingsModalProps) {
  const { settings, setSetting } = useSettings();
  const settingsLog = useRef(debug.category("config"));

  // Modal behavior (escape key, scroll prevention)
  useModalBehavior({ isOpen, onClose });

  // Drag state
  const [position, setPosition] = useState({ x: 0, y: 0 });
  const [isDragging, setIsDragging] = useState(false);
  const dragStart = useRef({ x: 0, y: 0 });
  const modalRef = useRef<HTMLDivElement>(null);

  // Debug state (for checkbox reactivity)
  const [debugEnabled, setDebugEnabled] = useState(isDebug());

  // Reset position when modal opens
  useEffect(() => {
    if (isOpen) {
      setPosition({ x: 0, y: 0 });
    }
  }, [isOpen]);

  // Handle drag
  useEffect(() => {
    if (!isDragging) return;

    const handleMouseMove = (e: MouseEvent) => {
      setPosition({
        x: e.clientX - dragStart.current.x,
        y: e.clientY - dragStart.current.y,
      });
    };

    const handleMouseUp = () => {
      setIsDragging(false);
    };

    window.addEventListener("mousemove", handleMouseMove);
    window.addEventListener("mouseup", handleMouseUp);

    return () => {
      window.removeEventListener("mousemove", handleMouseMove);
      window.removeEventListener("mouseup", handleMouseUp);
    };
  }, [isDragging]);

  const handleDragStart = (e: MouseEvent) => {
    // Don't start drag if clicking on close button
    if ((e.target as HTMLElement).closest(".settings-close")) return;

    setIsDragging(true);
    dragStart.current = {
      x: e.clientX - position.x,
      y: e.clientY - position.y,
    };
    e.preventDefault();
  };

  useEffect(() => {
    settingsLog.current.log(isOpen ? "SettingsModal open" : "SettingsModal closed");
  }, [isOpen]);

  useEffect(() => {
    settingsLog.current.log("SettingsModal mount");
    return () => settingsLog.current.log("SettingsModal unmount");
  }, []);

  if (!isOpen) return null;

  // Helper to get typed value from event
  const selectValue = (e: Event) => (e.target as HTMLSelectElement).value;
  const inputValue = (e: Event) => (e.target as HTMLInputElement).value;
  const inputInt = (e: Event) => parseInt(inputValue(e), 10);
  const inputOptionalInt = (e: Event) => {
    const raw = inputValue(e).trim();
    return raw.length === 0 ? 0 : parseInt(raw, 10);
  };
  const inputFloat = (e: Event) => parseFloat(inputValue(e));
  const inputLineHeight = (e: Event) => {
    const value = inputFloat(e);
    if (!Number.isFinite(value) || value <= 2.0) {
      return settings.fontSize;
    }
    return Math.round(value / 0.25) * 0.25;
  };
  const inputChecked = (e: Event) => (e.target as HTMLInputElement).checked;

  const modalStyle = {
    transform: `translate(calc(-50% + ${position.x}px), calc(-50% + ${position.y}px))`,
  };

  const logInputEvent = (label: string, e: Event) => {
    const target = e.target as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement;
    const tag = (target as HTMLElement)?.tagName ?? "unknown";
    const type = (target as HTMLInputElement).type ?? "";
    const value = "value" in target ? target.value : "";
    const checked = "checked" in target ? String((target as HTMLInputElement).checked) : "";
    settingsLog.current.log(
      `${label} tag=${tag} type=${type} value=${value} checked=${checked}`
    );
  };

  return (
    <div
      ref={modalRef}
      class={`settings-modal glassContainer ${isDragging ? "settings-modal--dragging" : ""}`}
      style={modalStyle}
      onClick={(e) => e.stopPropagation()}
    >
      <div
        class="settings-inner"
        onInput={(e) => logInputEvent("INPUT", e)}
        onChange={(e) => logInputEvent("CHANGE", e)}
      >
        <div class="settings-header" onMouseDown={handleDragStart}>
          <h2>Settings</h2>
          <button class="settings-close" onClick={onClose} aria-label="Close">
            ×
          </button>
        </div>

        <div class="settings-content">
          {/* Theme */}
          <div class="settings-section">
            <h3>Appearance</h3>

            <label class="settings-field">
              <span class="settings-label">Theme</span>
              <select
                value={settings.theme}
                onChange={(e) => setSetting("theme", selectValue(e))}
              >
                {THEMES.map((t) => (
                  <option key={t.selector} value={t.selector}>
                    {t.name}
                  </option>
                ))}
              </select>
            </label>

            <label class="settings-field">
              <span class="settings-label">Font Size</span>
              <input
                type="number"
                min="8"
                max="32"
                value={settings.fontSize}
                onInput={(e) => setSetting("fontSize", inputInt(e))}
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Font Family</span>
              <input
                type="text"
                value={settings.fontFamily}
                onInput={(e) => setSetting("fontFamily", inputValue(e))}
                placeholder="JetBrains Mono, monospace"
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Symbol Font Size</span>
              <input
                type="number"
                min="0"
                max="64"
                value={settings.symbolFontSize === 0 ? "" : settings.symbolFontSize}
                onInput={(e) => setSetting("symbolFontSize", inputOptionalInt(e))}
                placeholder="(auto)"
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Symbol Font Family</span>
              <input
                type="text"
                value={settings.symbolFontFamily}
                onInput={(e) => setSetting("symbolFontFamily", inputValue(e))}
                placeholder="(auto)"
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Font Weight</span>
              <select
                value={settings.fontStyle}
                onChange={(e) => setSetting("fontStyle", selectValue(e))}
              >
                <option value="100">Thin (100)</option>
                <option value="200">ExtraLight (200)</option>
                <option value="300">Light (300)</option>
                <option value="normal">Normal (400)</option>
                <option value="500">Medium (500)</option>
                <option value="600">SemiBold (600)</option>
                <option value="bold">Bold (700)</option>
                <option value="800">ExtraBold (800)</option>
                <option value="900">Black (900)</option>
              </select>
            </label>

            <label class="settings-field">
              <span class="settings-label">Font Features</span>
              <input
                type="text"
                value={settings.fontFeature}
                onInput={(e) => setSetting("fontFeature", inputValue(e))}
                placeholder='"liga" 1, "ss01" 1'
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Line Height (px)</span>
              <input
                type="number"
                min="4"
                max="96"
                step="0.25"
                value={settings.lineHeight}
                onInput={(e) => setSetting("lineHeight", inputLineHeight(e))}
              />
            </label>
          </div>

          {/* Cursor */}
          <div class="settings-section">
            <h3>Cursor</h3>

            <label class="settings-field">
              <span class="settings-label">Style</span>
              <select
                value={settings.cursorStyle}
                onChange={(e) =>
                  setSetting(
                    "cursorStyle",
                    selectValue(e) as SettingsState["cursorStyle"]
                  )
                }
              >
                <option value="block">Block</option>
                <option value="bar">Bar</option>
                <option value="underline">Underline</option>
                <option value="block_hollow">Block Hollow</option>
              </select>
            </label>

            <label class="settings-field">
              <span class="settings-label">Color</span>
              <input
                type="text"
                value={settings.cursorColor}
                onInput={(e) => setSetting("cursorColor", inputValue(e))}
                placeholder="#hex, cell-foreground, cell-background"
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Text Color</span>
              <input
                type="text"
                value={settings.cursorText}
                onInput={(e) => setSetting("cursorText", inputValue(e))}
                placeholder="#hex, cell-foreground, cell-background"
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Opacity</span>
              <input
                type="number"
                min="0"
                max="1"
                step="0.1"
                value={settings.cursorOpacity}
                onInput={(e) => setSetting("cursorOpacity", inputFloat(e))}
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Blink</span>
              <select
                value={settings.cursorBlink}
                onChange={(e) =>
                  setSetting(
                    "cursorBlink",
                    selectValue(e) as SettingsState["cursorBlink"]
                  )
                }
              >
                <option value="">(auto)</option>
                <option value="true">true</option>
                <option value="false">false</option>
              </select>
            </label>
          </div>

          {/* Layout */}
          <div class="settings-section">
            <h3>Layout</h3>

            <label class="settings-field">
              <span class="settings-label">Spacing</span>
              <select
                value={settings.spacing}
                onChange={(e) =>
                  setSetting(
                    "spacing",
                    selectValue(e) as SettingsState["spacing"]
                  )
                }
              >
                <option value="compact">Compact (2px/4px)</option>
                <option value="comfortable">Comfortable (8px/16px)</option>
              </select>
            </label>
          </div>

          {/* Bell */}
          <div class="settings-section">
            <h3>Bell</h3>

            <label class="settings-field">
              <span class="settings-label">Features</span>
              <input
                type="text"
                value={settings.bellFeatures}
                onInput={(e) => setSetting("bellFeatures", inputValue(e))}
                placeholder="audio,attention,title"
              />
            </label>
          </div>

          {/* Selection */}
          <div class="settings-section">
            <h3>Selection</h3>

            <label class="settings-field settings-field--checkbox">
              <input
                type="checkbox"
                checked={settings.selectionClearOnCopy}
                onChange={(e) =>
                  setSetting("selectionClearOnCopy", inputChecked(e))
                }
              />
              <span class="settings-label">Clear selection on copy</span>
            </label>
          </div>

          {/* Mouse */}
          <div class="settings-section">
            <h3>Mouse</h3>

            <label class="settings-field settings-field--checkbox">
              <input
                type="checkbox"
                checked={settings.mouseMove}
                onChange={(e) => setSetting("mouseMove", inputChecked(e))}
              />
              <span class="settings-label">Send mouse move events</span>
            </label>
          </div>

          {/* Developer */}
          <div class="settings-section">
            <h3>Developer</h3>

            <label class="settings-field settings-field--checkbox">
              <input
                type="checkbox"
                checked={debugEnabled}
                onChange={(e) => {
                  const enabled = inputChecked(e);
                  setDebugEnabled(enabled);
                  setDebug(enabled);
                }}
              />
              <span class="settings-label">Enable debug logging (console)</span>
            </label>
          </div>
        </div>
      </div>
    </div>
  );
}
