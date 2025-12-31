import { h } from "preact";
import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { useTerminalDimensions } from "../hooks/useTerminalDimensions";
import { TerminalConnection } from "../terminal/connection";
import { KeyboardHandler, createKeyboardHandler } from "../terminal/keyboard";
import { IMEHandler, createIMEHandler } from "../terminal/ime";
import { cellToChar } from "../../../protocol/schema/cell";
import { getStyle, ColorTag, Underline } from "../../../protocol/schema/style";
import { SettingsModal } from "./SettingsModal";
import * as config from "../config";
import type { TerminalSnapshot } from "../terminal/connection";
import type { Cell } from "../../../protocol/schema/cell";
import type { Style, StyleTable } from "../../../protocol/schema/style";

export function App() {
  const [connected, setConnected] = useState(false);
  const [snapshot, setSnapshot] = useState<TerminalSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [theme, setTheme] = useState(() => config.get('theme'));
  const [cursorStyle, setCursorStyle] = useState(() => config.get('cursorStyle'));
  const [cursorColor, setCursorColor] = useState(() => config.get('cursorColor'));
  const [cursorText, setCursorText] = useState(() => config.get('cursorText'));
  const [cursorBlink, setCursorBlink] = useState(() => config.get('cursorBlink'));
  const [calculatedDimensions, setCalculatedDimensions] = useState({ cols: 80, rows: 24 });
  const connectionRef = useRef<TerminalConnection | null>(null);
  
  const handleDimensionsChange = useCallback((cols: number, rows: number) => {
    setCalculatedDimensions({ cols, rows });
    // TODO(du-9yo): Send resize to server when connection supports it
  }, []);

  // Apply config on mount
  useEffect(() => {
    config.applyToCSS();
  }, []);

  // Listen for config changes
  useEffect(() => {
    return config.onChange((key, value) => {
      if (key === 'theme') {
        setTheme(value as string);
      } else if (key === 'cursorStyle') {
        setCursorStyle(value as typeof cursorStyle);
      } else if (key === 'cursorColor') {
        setCursorColor(value as string);
      } else if (key === 'cursorText') {
        setCursorText(value as string);
      } else if (key === 'cursorBlink') {
        setCursorBlink(value as '' | 'true' | 'false');
      }
    });
  }, []);

  useEffect(() => {
    const conn = new TerminalConnection();
    connectionRef.current = conn;

    conn.onConnect = () => {
      setConnected(true);
      setError(null);
    };

    conn.onDisconnect = () => {
      setConnected(false);
    };

    conn.onError = (err) => {
      setError(err);
    };

    conn.onSnapshot = (snap) => {
      setSnapshot(snap);
    };

    conn.connect();

    return () => {
      conn.disconnect();
    };
  }, []);

  return (
    <div class="app" data-theme={theme}>
      <aside class="sidebar">
        <div class="sidebar-logo" title="Dullahan">D</div>
        <div class="sidebar-spacer" />
        <button 
          class={`sidebar-btn ${connected ? 'sidebar-btn--connected' : 'sidebar-btn--disconnected'}`}
          title={connected ? 'Connected' : 'Disconnected'}
        >
          {connected ? '●' : '○'}
        </button>
        <button 
          class="sidebar-btn" 
          onClick={() => setSettingsOpen(true)}
          title="Settings"
        >
          ⚙
        </button>
      </aside>

      <main class="main">
        {error && <div class="error">Error: {error}</div>}
        
        <div class="terminal-grid">
          {/* Terminal 1 - Active */}
          <div class="terminal-pane">
            <div class="terminal-titlebar">
              <span class="terminal-title">Terminal 1</span>
              <span class="terminal-size" title={`Server: ${snapshot?.cols}×${snapshot?.rows}, Visible: ${calculatedDimensions.cols}×${calculatedDimensions.rows}`}>
                {snapshot ? `${calculatedDimensions.cols}×${calculatedDimensions.rows}` : '—'}
              </span>
            </div>
            {snapshot ? (
              <TerminalView 
                snapshot={snapshot} 
                cursorStyle={cursorStyle}
                cursorColor={cursorColor}
                cursorText={cursorText}
                cursorBlink={cursorBlink}
                onDimensionsChange={handleDimensionsChange}
                connection={connectionRef.current}
              />
            ) : (
              <div class="terminal terminal--empty">
                {connected ? "Waiting..." : "Connecting..."}
              </div>
            )}
          </div>

          {/* Terminal 2 - Placeholder */}
          <TerminalPlaceholder title="Terminal 2" />

          {/* Terminal 3 - Placeholder */}
          <TerminalPlaceholder title="Terminal 3" />
        </div>
      </main>

      <SettingsModal 
        isOpen={settingsOpen} 
        onClose={() => setSettingsOpen(false)} 
      />
    </div>
  );
}

interface TerminalViewProps {
  snapshot: TerminalSnapshot;
  cursorStyle: 'block' | 'bar' | 'underline' | 'block_hollow';
  cursorColor: string;
  cursorText: string;
  cursorBlink: '' | 'true' | 'false';
  onDimensionsChange?: (cols: number, rows: number) => void;
  connection: TerminalConnection | null;
}

function TerminalView({ snapshot, cursorStyle, cursorColor, cursorText, cursorBlink, onDimensionsChange, connection }: TerminalViewProps) {
  const { cols, rows, cursor, cells, styles } = snapshot;
  const terminalRef = useRef<HTMLPreElement>(null);
  const keyboardRef = useRef<KeyboardHandler | null>(null);
  const imeRef = useRef<IMEHandler | null>(null);
  const dimensions = useTerminalDimensions(terminalRef);

  // Report dimension changes
  useEffect(() => {
    if (onDimensionsChange && dimensions.cols > 0 && dimensions.rows > 0) {
      onDimensionsChange(dimensions.cols, dimensions.rows);
    }
  }, [dimensions.cols, dimensions.rows, onDimensionsChange]);

  // Setup keyboard handler
  useEffect(() => {
    if (!terminalRef.current) return;

    const keyboard = createKeyboardHandler();
    const ime = createIMEHandler();
    keyboardRef.current = keyboard;
    imeRef.current = ime;

    keyboard.attach(terminalRef.current, (msg) => {
      if (connection?.isConnected) {
        connection.sendKey(msg);
      }
    });

    ime.setCallback((msg) => {
      if (connection?.isConnected) {
        connection.sendText(msg);
      }
    });

    // Auto-focus terminal on mount
    keyboard.focus();

    return () => {
      keyboard.detach();
      ime.clearCallback();
    };
  }, [connection]);

  // Handle wheel events for scrollback
  const handleWheel = useCallback((e: WheelEvent) => {
    e.preventDefault();
    if (!connection?.isConnected) return;
    
    // Convert wheel delta to rows (roughly 3 rows per scroll tick)
    const delta = Math.sign(e.deltaY) * 3;
    connection.sendScroll(delta);
  }, [connection]);

  // Attach wheel handler
  useEffect(() => {
    const el = terminalRef.current;
    if (!el) return;
    
    el.addEventListener('wheel', handleWheel, { passive: false });
    return () => el.removeEventListener('wheel', handleWheel);
  }, [handleWheel]);

  // Convert cells to styled runs
  const lines = cellsToRuns(cells, styles, cols, rows);

  // Show scrollback indicator if not at bottom
  const isScrolledUp = snapshot.scrollback.viewportTop < 
    snapshot.scrollback.totalRows - rows;

  return (
    <pre class="terminal" ref={terminalRef} tabIndex={0}>
      {isScrolledUp && (
        <div class="scrollback-indicator">
          ↑ {snapshot.scrollback.totalRows - snapshot.scrollback.viewportTop - rows} lines above
        </div>
      )}
      {lines.map((runs, y) => (
        <div key={y} class="terminal-line">
          {renderLine(runs, y, cursor, cursorStyle, cursorColor, cursorText, cursorBlink)}
        </div>
      ))}
    </pre>
  );
}

/** Placeholder terminal that shows dimensions */
interface TerminalPlaceholderProps {
  title: string;
}

function TerminalPlaceholder({ title }: TerminalPlaceholderProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const dimensions = useTerminalDimensions(terminalRef);

  return (
    <div class="terminal-pane terminal-pane--placeholder">
      <div class="terminal-titlebar">
        <span class="terminal-title">{title}</span>
        <span class="terminal-size">
          {dimensions.cols > 0 ? `${dimensions.cols}×${dimensions.rows}` : '—'}
        </span>
      </div>
      <div class="terminal terminal--empty" ref={terminalRef}>
        <span class="terminal-placeholder-text">Empty</span>
      </div>
    </div>
  );
}

/** A run of consecutive cells with the same style */
interface Run {
  text: string;
  styleId: number;
  style: Style;
}

/** Convert cells to lines of styled runs */
function cellsToRuns(
  cells: Cell[],
  styles: StyleTable,
  cols: number,
  rows: number
): Run[][] {
  const lines: Run[][] = [];

  for (let y = 0; y < rows; y++) {
    const runs: Run[] = [];
    let currentRun: Run | null = null;

    for (let x = 0; x < cols; x++) {
      const idx = y * cols + x;
      const cell = cells[idx];
      const char = cell ? cellToChar(cell) : " ";
      const styleId = cell?.styleId ?? 0;

      if (currentRun && currentRun.styleId === styleId) {
        currentRun.text += char;
      } else {
        const style = getStyle(styles, styleId);
        currentRun = { text: char, styleId, style };
        runs.push(currentRun);
      }
    }

    lines.push(runs);
  }

  return lines;
}

/** Get cell color as CSS value */
function getCellColor(style: Style, type: 'fg' | 'bg'): string | undefined {
  const color = type === 'fg' ? style.fgColor : style.bgColor;
  if (color.tag === ColorTag.RGB) {
    return `rgb(${color.r},${color.g},${color.b})`;
  } else if (color.tag === ColorTag.PALETTE) {
    return `var(--c${color.index})`;
  }
  return undefined;
}

/** Resolve cursor color setting to actual CSS value */
function resolveCursorColor(
  setting: string,
  cellStyle: Style,
  defaultVar: string
): string | undefined {
  if (!setting) return undefined; // Use CSS default (theme color)
  if (setting === 'cell-foreground') return getCellColor(cellStyle, 'fg');
  if (setting === 'cell-background') return getCellColor(cellStyle, 'bg');
  return setting; // Custom color value
}

/** Render a line of runs, inserting cursor if needed */
function renderLine(
  runs: Run[],
  y: number,
  cursor: TerminalSnapshot["cursor"],
  cursorStyle: 'block' | 'bar' | 'underline' | 'block_hollow',
  cursorColor: string,
  cursorText: string,
  cursorBlink: '' | 'true' | 'false'
): preact.JSX.Element {
  // If cursor is not on this line, render runs directly
  if (!cursor.visible || cursor.y !== y) {
    return (
      <>
        {runs.map((run, i) => (
          <span key={i} class={styleToClasses(run.style)} style={styleToInline(run.style)}>
            {run.text}
          </span>
        ))}
      </>
    );
  }

  // Cursor is on this line - need to split at cursor position
  const elements: preact.JSX.Element[] = [];
  let x = 0;
  // '' (auto) = blink by default, 'true' = blink, 'false' = no blink
  const shouldBlink = cursorBlink !== 'false';
  const cursorClass = `cursor-${cursorStyle}${shouldBlink ? ' cursor-blink' : ''}`;
  // For non-block cursors, preserve original text styling
  const preserveStyle = cursorStyle !== 'block';

  for (let i = 0; i < runs.length; i++) {
    const run = runs[i]!;
    const runStart = x;
    const runEnd = x + run.text.length;

    if (cursor.x >= runStart && cursor.x < runEnd) {
      // Cursor is in this run - split it
      const offset = cursor.x - runStart;
      const before = run.text.slice(0, offset);
      const cursorChar = run.text[offset] || " ";
      const after = run.text.slice(offset + 1);

      if (before) {
        elements.push(
          <span key={`${i}-before`} class={styleToClasses(run.style)} style={styleToInline(run.style)}>
            {before}
          </span>
        );
      }

      // Build cursor style
      const baseStyle = preserveStyle ? styleToInline(run.style) || {} : {};
      const cursorBg = resolveCursorColor(cursorColor, run.style, '--term-cursor-bg');
      const cursorFg = resolveCursorColor(cursorText, run.style, '--term-cursor-fg');
      
      const cursorInlineStyle: h.JSX.CSSProperties = { ...baseStyle };
      if (cursorBg) {
        cursorInlineStyle['--cursor-bg'] = cursorBg;
      }
      if (cursorFg && cursorStyle === 'block') {
        // Text color only applies to block cursor
        cursorInlineStyle.color = cursorFg;
      }
      
      const classes = preserveStyle 
        ? `${cursorClass} ${styleToClasses(run.style)}`.trim()
        : cursorClass;
      
      elements.push(
        <span 
          key={`${i}-cursor`} 
          class={classes} 
          style={Object.keys(cursorInlineStyle).length ? cursorInlineStyle : undefined}
        >
          {cursorChar}
        </span>
      );

      if (after) {
        elements.push(
          <span key={`${i}-after`} class={styleToClasses(run.style)} style={styleToInline(run.style)}>
            {after}
          </span>
        );
      }
    } else {
      elements.push(
        <span key={i} class={styleToClasses(run.style)} style={styleToInline(run.style)}>
          {run.text}
        </span>
      );
    }

    x = runEnd;
  }

  // Cursor beyond end of line
  if (cursor.x >= x) {
    elements.push(
      <span key="cursor-end" class={cursorClass}>
        {" "}
      </span>
    );
  }

  return <>{elements}</>;
}

/** Convert style to CSS class names (for palette colors + attributes) */
function styleToClasses(style: Style): string {
  const classes: string[] = [];

  // Foreground color (palette only - RGB uses inline style)
  if (style.fgColor.tag === ColorTag.PALETTE) {
    classes.push(`fg${style.fgColor.index}`);
  }

  // Background color (palette only)
  if (style.bgColor.tag === ColorTag.PALETTE) {
    classes.push(`bg${style.bgColor.index}`);
  }

  // Attributes
  if (style.flags.bold) classes.push("bold");
  if (style.flags.italic) classes.push("italic");
  if (style.flags.faint) classes.push("faint");
  if (style.flags.blink) classes.push("blink");
  if (style.flags.inverse) classes.push("inverse");
  if (style.flags.invisible) classes.push("invisible");
  if (style.flags.strikethrough) classes.push("strikethrough");
  if (style.flags.overline) classes.push("overline");

  // Underline styles
  switch (style.flags.underline) {
    case Underline.SINGLE:
      classes.push("underline");
      break;
    case Underline.DOUBLE:
      classes.push("underline-double");
      break;
    case Underline.CURLY:
      classes.push("underline-curly");
      break;
    case Underline.DOTTED:
      classes.push("underline-dotted");
      break;
    case Underline.DASHED:
      classes.push("underline-dashed");
      break;
  }

  return classes.join(" ");
}

/** Convert style to inline CSS (for RGB colors only) */
function styleToInline(style: Style): h.JSX.CSSProperties | undefined {
  const css: h.JSX.CSSProperties = {};
  let hasInline = false;

  // RGB foreground
  if (style.fgColor.tag === ColorTag.RGB) {
    css.color = `rgb(${style.fgColor.r},${style.fgColor.g},${style.fgColor.b})`;
    hasInline = true;
  }

  // RGB background
  if (style.bgColor.tag === ColorTag.RGB) {
    css.backgroundColor = `rgb(${style.bgColor.r},${style.bgColor.g},${style.bgColor.b})`;
    hasInline = true;
  }

  // Underline color (always inline if set, CSS doesn't support this well)
  if (style.underlineColor.tag === ColorTag.RGB) {
    css.textDecorationColor = `rgb(${style.underlineColor.r},${style.underlineColor.g},${style.underlineColor.b})`;
    hasInline = true;
  } else if (style.underlineColor.tag === ColorTag.PALETTE) {
    css.textDecorationColor = `var(--c${style.underlineColor.index})`;
    hasInline = true;
  }

  return hasInline ? css : undefined;
}
