import { h } from "preact";
import { useState, useEffect, useRef } from "preact/hooks";
import * as config from "../config";
import { THEMES } from "../themes";

interface SettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export function SettingsModal({ isOpen, onClose }: SettingsModalProps) {
  const [theme, setTheme] = useState(() => config.get('theme'));
  const [spacing, setSpacing] = useState(() => config.get('spacing'));
  const [fontSize, setFontSize] = useState(() => config.get('fontSize'));
  const [fontFamily, setFontFamily] = useState(() => config.get('fontFamily'));
  const [fontStyle, setFontStyle] = useState(() => config.get('fontStyle'));
  const [fontFeature, setFontFeature] = useState(() => config.get('fontFeature'));
  const [cursorStyle, setCursorStyle] = useState(() => config.get('cursorStyle'));
  const [cursorColor, setCursorColor] = useState(() => config.get('cursorColor'));
  const [cursorText, setCursorText] = useState(() => config.get('cursorText'));
  const [cursorOpacity, setCursorOpacity] = useState(() => config.get('cursorOpacity'));
  const [cursorBlink, setCursorBlink] = useState(() => config.get('cursorBlink'));

  // Drag state
  const [position, setPosition] = useState({ x: 0, y: 0 });
  const [isDragging, setIsDragging] = useState(false);
  const dragStart = useRef({ x: 0, y: 0 });
  const modalRef = useRef<HTMLDivElement>(null);

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

    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);

    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isDragging]);

  const handleDragStart = (e: MouseEvent) => {
    // Don't start drag if clicking on close button
    if ((e.target as HTMLElement).closest('.settings-close')) return;
    
    setIsDragging(true);
    dragStart.current = {
      x: e.clientX - position.x,
      y: e.clientY - position.y,
    };
    e.preventDefault();
  };

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

  const handleSpacingChange = (e: Event) => {
    const value = (e.target as HTMLSelectElement).value as 'compact' | 'comfortable';
    setSpacing(value);
    config.set('spacing', value);
    config.applyToCSS();
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

  const handleFontStyleChange = (e: Event) => {
    const value = (e.target as HTMLSelectElement).value;
    setFontStyle(value);
    config.set('fontStyle', value);
    config.applyToCSS();
  };

  const handleFontFeatureChange = (e: Event) => {
    const value = (e.target as HTMLInputElement).value;
    setFontFeature(value);
    config.set('fontFeature', value);
    config.applyToCSS();
  };

  const handleCursorStyleChange = (e: Event) => {
    const value = (e.target as HTMLSelectElement).value as 'block' | 'bar' | 'underline' | 'block_hollow';
    setCursorStyle(value);
    config.set('cursorStyle', value);
  };

  const handleCursorColorChange = (e: Event) => {
    const value = (e.target as HTMLInputElement).value;
    setCursorColor(value);
    config.set('cursorColor', value);
  };

  const handleCursorTextChange = (e: Event) => {
    const value = (e.target as HTMLInputElement).value;
    setCursorText(value);
    config.set('cursorText', value);
  };

  const handleCursorOpacityChange = (e: Event) => {
    const value = parseFloat((e.target as HTMLInputElement).value);
    setCursorOpacity(value);
    config.set('cursorOpacity', value);
    config.applyToCSS();
  };

  const handleCursorBlinkChange = (e: Event) => {
    const value = (e.target as HTMLInputElement).checked;
    setCursorBlink(value);
    config.set('cursorBlink', value);
  };

  const modalStyle = {
    transform: `translate(calc(-50% + ${position.x}px), calc(-50% + ${position.y}px))`,
  };

  return (
    <div 
      ref={modalRef}
      class={`settings-modal glass ${isDragging ? 'settings-modal--dragging' : ''}`}
      style={modalStyle}
      onClick={(e) => e.stopPropagation()}
    >
      <div class="settings-inner">
        <div 
          class="settings-header" 
          onMouseDown={handleDragStart}
        >
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

            <label class="settings-field">
              <span class="settings-label">Font Weight</span>
              <select value={fontStyle} onChange={handleFontStyleChange}>
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
                value={fontFeature}
                onChange={handleFontFeatureChange}
                placeholder='"liga" 1, "ss01" 1'
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
                <option value="block_hollow">Block Hollow</option>
              </select>
            </label>

            <label class="settings-field">
              <span class="settings-label">Color</span>
              <input
                type="text"
                value={cursorColor}
                onChange={handleCursorColorChange}
                placeholder="#hex, cell-foreground, cell-background"
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Text Color</span>
              <input
                type="text"
                value={cursorText}
                onChange={handleCursorTextChange}
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
                value={cursorOpacity}
                onChange={handleCursorOpacityChange}
              />
            </label>

            <label class="settings-field">
              <span class="settings-label">Blink</span>
              <input
                type="checkbox"
                checked={cursorBlink}
                onChange={handleCursorBlinkChange}
              />
            </label>
          </div>

          {/* Layout */}
          <div class="settings-section">
            <h3>Layout</h3>
            
            <label class="settings-field">
              <span class="settings-label">Spacing</span>
              <select value={spacing} onChange={handleSpacingChange}>
                <option value="compact">Compact (2px/4px)</option>
                <option value="comfortable">Comfortable (8px/16px)</option>
              </select>
            </label>
          </div>
        </div>

      </div>
    </div>
  );
}
