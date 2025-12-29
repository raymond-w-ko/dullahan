// Dullahan Protocol Types
// Shared between server (Zig) and client (TypeScript)

// ============================================================================
// Server -> Client Messages
// ============================================================================

export type ServerMessage =
  | { type: "snapshot"; data: TerminalSnapshot }
  | { type: "output"; data: string } // Raw terminal output (for now)
  | { type: "bell" }
  | { type: "title"; title: string };

// Full terminal state snapshot
export interface TerminalSnapshot {
  // Dimensions
  cols: number;
  rows: number;

  // Cursor state
  cursor: CursorState;

  // Screen content - array of rows, each row is array of cells
  cells: Cell[][];

  // Active screen (primary or alternate)
  altScreen: boolean;
}

export interface CursorState {
  x: number;
  y: number;
  visible: boolean;
  style: "block" | "underline" | "bar";
}

// A single terminal cell
export interface Cell {
  // Character (empty string for blank)
  char: string;

  // Foreground color (null = default)
  fg: Color | null;

  // Background color (null = default)
  bg: Color | null;

  // Style flags
  bold: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
}

// Color can be palette index or RGB
export type Color =
  | { type: "palette"; index: number }
  | { type: "rgb"; r: number; g: number; b: number };

// ============================================================================
// Client -> Server Messages
// ============================================================================

export type ClientMessage =
  | { type: "input"; data: string } // Keyboard input (raw bytes)
  | { type: "resize"; cols: number; rows: number }
  | { type: "ping" };

// ============================================================================
// Default/empty values
// ============================================================================

export const DEFAULT_CELL: Cell = {
  char: " ",
  fg: null,
  bg: null,
  bold: false,
  italic: false,
  underline: false,
  inverse: false,
};

export function createEmptySnapshot(cols: number, rows: number): TerminalSnapshot {
  const cells: Cell[][] = [];
  for (let y = 0; y < rows; y++) {
    const row: Cell[] = [];
    for (let x = 0; x < cols; x++) {
      row.push({ ...DEFAULT_CELL });
    }
    cells.push(row);
  }

  return {
    cols,
    rows,
    cursor: { x: 0, y: 0, visible: true, style: "block" },
    cells,
    altScreen: false,
  };
}
