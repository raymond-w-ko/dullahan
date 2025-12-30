import { h } from "preact";
import { useState, useEffect } from "preact/hooks";
import * as config from "../config";
import { THEMES } from "../themes";

interface SettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export function SettingsModal({ isOpen, onClose }: SettingsModalProps) {
  const [theme, setTheme] = useState(() => config.get('theme'));
  const [fontSize, setFontSize] = useState(() => config.get('fontSize'));
  const [fontFamily, setFontFamily] = useState(() => config.get('fontFamily'));
  const [cursorStyle, setCursorStyle] = useState(() => config.get('cursorStyle'));
  const [cursorBlink, setCursorBlink] = useState(() => config.get('cursorBlink'));
  const [paddingX, setPaddingX] = useState(() => config.get('windowPaddingX'));
  const [paddingY, setPaddingY] = useState(() => config.get('windowPaddingY'));

  // Close on escape key
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && isOpen) {
        onClose();
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isOpen, onClose]);

  // Prevent body scroll when modal is open
  useEffect(() => {
    if (isOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = '';
    }
    return () => { document.body.style.overflow = ''; };
  }, [isOpen]);

  if (!isOpen) return null;

  const handleThemeChange = (e: Event) => {
    const value = (e.target as HTMLSelectElement).value;
    setTheme(value);
    config.set('theme', value);
    // Apply theme immediately
    document.querySelector('.app')?.setAttribute('data-theme', value);
  };

  const handleFontSizeChange = (e: Event) => {
    const value = parseInt((e.target as HTMLInputElement).value, 10);
    setFontSize(value);
    config.set('fontSize', value);
    config.applyToCSS();
  };

  const handleFontFamilyChange = (e: Event) => {
    const value = (e.target as HTMLInputElement).value;
    setFontFamily(value);
    config.set('fontFamily', value);
    config.applyToCSS();
  };

  const handleCursorStyleChange = (e: Event) => {
    const value = (e.target as HTMLSelectElement).value as 'block' | 'bar' | 'underline';
    setCursorStyle(value);
    config.set('cursorStyle', value);
  };

  const handleCursorBlinkChange = (e: Event) => {
    const value = (e.target as HTMLInputElement).checked;
    setCursorBlink(value);
    config.set('cursorBlink', value);
  };

  const handlePaddingXChange = (e: Event) => {
    const value = parseInt((e.target as HTMLInputElement).value, 10);
    setPaddingX(value);
    config.set('windowPaddingX', value);
    config.applyToCSS();
  };

  const handlePaddingYChange = (e: Event) => {
    const value = parseInt((e.target as HTMLInputElement).value, 10);
    setPaddingY(value);
    config.set('windowPaddingY', value);
    config.applyToCSS();
  };

  return (
    <div class="settings-overlay" onClick={onClose}>
      <div class="settings-modal glass" onClick={(e) => e.stopPropagation()}>
        <div class="settings-header">
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
              <select value={theme} onChange={handleThemeChange}>
                {THEMES.map(t => (
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
                value={fontSize}
                onChange={handleFontSizeChange}
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Font Family</span>
              <input
                type="text"
                value={fontFamily}
                onChange={handleFontFamilyChange}
                placeholder="JetBrains Mono, monospace"
              />
            </label>
          </div>

          {/* Cursor */}
          <div class="settings-section">
            <h3>Cursor</h3>
            
            <label class="settings-field">
              <span class="settings-label">Style</span>
              <select value={cursorStyle} onChange={handleCursorStyleChange}>
                <option value="block">Block</option>
                <option value="bar">Bar</option>
                <option value="underline">Underline</option>
              </select>
            </label>

            <label class="settings-field settings-field--checkbox">
              <input
                type="checkbox"
                checked={cursorBlink}
                onChange={handleCursorBlinkChange}
              />
              <span class="settings-label">Blink</span>
            </label>
          </div>

          {/* Layout */}
          <div class="settings-section">
            <h3>Layout</h3>
            
            <label class="settings-field">
              <span class="settings-label">Padding X</span>
              <input
                type="number"
                min="0"
                max="50"
                value={paddingX}
                onChange={handlePaddingXChange}
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Padding Y</span>
              <input
                type="number"
                min="0"
                max="50"
                value={paddingY}
                onChange={handlePaddingYChange}
              />
            </label>
          </div>
        </div>

        <div class="settings-footer">
          <button class="settings-btn" onClick={onClose}>Done</button>
        </div>
      </div>
    </div>
  );
}
