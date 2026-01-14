/**
 * Tests for terminal cell dimension calculation utilities.
 */

import { describe, test, expect, beforeEach, mock } from "bun:test";
import {
  getCellDimensions,
  getPadding,
  calculateTerminalSize,
  getOrCreateMeasureElement,
  MIN_CELL_WIDTH,
  MIN_CELL_HEIGHT,
  MAX_TERMINAL_SIZE,
  type CellDimensions,
  type Padding,
} from "./dimensions";

// Mock document.createElement globally before any tests run
(globalThis as any).document = {
  createElement: (tagName: string) => ({
    className: "",
    textContent: "",
    getBoundingClientRect: () => ({
      width: 0,
      height: 0,
      top: 0,
      left: 0,
      bottom: 0,
      right: 0,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    }),
  }),
};

// Mock HTMLElement with getBoundingClientRect
function createMockElement(rect: { width: number; height: number }): HTMLElement {
  return {
    getBoundingClientRect: () => ({
      width: rect.width,
      height: rect.height,
      top: 0,
      left: 0,
      bottom: rect.height,
      right: rect.width,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    }),
  } as HTMLElement;
}

// Mock container element with computed style and children
// The measureElement is pre-created and returned by querySelector to avoid document.createElement
function createMockContainer(options: {
  clientWidth: number;
  clientHeight: number;
  padding?: { left: number; right: number; top: number; bottom: number };
  measureRect?: { width: number; height: number };
  terminalPadding?: { left: number; right: number; top: number; bottom: number };
}): HTMLElement {
  const padding = options.padding ?? { left: 0, right: 0, top: 0, bottom: 0 };
  const measureRect = options.measureRect ?? { width: 8, height: 16 };
  const terminalPadding = options.terminalPadding;

  // Pre-create measure element so querySelector returns it (avoiding document.createElement)
  const measureElement = {
    className: "terminal-measure terminal-line",
    textContent: "X",
    getBoundingClientRect: () => ({
      width: measureRect.width,
      height: measureRect.height,
      top: 0,
      left: 0,
      bottom: measureRect.height,
      right: measureRect.width,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    }),
  } as unknown as HTMLElement;

  let terminalElement: HTMLElement | null = null;

  if (terminalPadding) {
    terminalElement = {
      style: {},
    } as HTMLElement;
    // Mock getComputedStyle for terminal element
    (terminalElement as any).__computedStyle = {
      paddingLeft: `${terminalPadding.left}px`,
      paddingRight: `${terminalPadding.right}px`,
      paddingTop: `${terminalPadding.top}px`,
      paddingBottom: `${terminalPadding.bottom}px`,
    };
  }

  const container = {
    clientWidth: options.clientWidth,
    clientHeight: options.clientHeight,
    querySelector: (selector: string) => {
      if (selector === ".terminal-measure") return measureElement;
      if (selector === ".terminal") return terminalElement;
      return null;
    },
    appendChild: () => {}, // No-op since measure already exists
  } as unknown as HTMLElement;

  // Mock getComputedStyle for container
  (container as any).__computedStyle = {
    paddingLeft: `${padding.left}px`,
    paddingRight: `${padding.right}px`,
    paddingTop: `${padding.top}px`,
    paddingBottom: `${padding.bottom}px`,
  };

  return container;
}

// Override getComputedStyle for our mock elements
globalThis.getComputedStyle = ((element: any) => {
  if (element.__computedStyle) {
    return element.__computedStyle;
  }
  return {
    paddingLeft: "0px",
    paddingRight: "0px",
    paddingTop: "0px",
    paddingBottom: "0px",
  };
}) as typeof getComputedStyle;

describe("getCellDimensions", () => {
  test("returns cell dimensions from element rect", () => {
    const element = createMockElement({ width: 8.5, height: 16.2 });
    const dims = getCellDimensions(element);
    expect(dims.cellWidth).toBe(8.5);
    expect(dims.cellHeight).toBe(16.2);
  });

  test("returns zero dimensions for zero-size element", () => {
    const element = createMockElement({ width: 0, height: 0 });
    const dims = getCellDimensions(element);
    expect(dims.cellWidth).toBe(0);
    expect(dims.cellHeight).toBe(0);
  });

  test("handles fractional dimensions", () => {
    const element = createMockElement({ width: 7.333, height: 15.666 });
    const dims = getCellDimensions(element);
    expect(dims.cellWidth).toBeCloseTo(7.333);
    expect(dims.cellHeight).toBeCloseTo(15.666);
  });
});

describe("getPadding", () => {
  test("parses padding from computed style", () => {
    const element = {
      __computedStyle: {
        paddingLeft: "10px",
        paddingRight: "20px",
        paddingTop: "5px",
        paddingBottom: "15px",
      },
    } as unknown as HTMLElement;

    const padding = getPadding(element);
    expect(padding.left).toBe(10);
    expect(padding.right).toBe(20);
    expect(padding.top).toBe(5);
    expect(padding.bottom).toBe(15);
    expect(padding.horizontal).toBe(30);
    expect(padding.vertical).toBe(20);
  });

  test("returns zero for no padding", () => {
    const element = {
      __computedStyle: {
        paddingLeft: "0px",
        paddingRight: "0px",
        paddingTop: "0px",
        paddingBottom: "0px",
      },
    } as unknown as HTMLElement;

    const padding = getPadding(element);
    expect(padding.left).toBe(0);
    expect(padding.right).toBe(0);
    expect(padding.top).toBe(0);
    expect(padding.bottom).toBe(0);
    expect(padding.horizontal).toBe(0);
    expect(padding.vertical).toBe(0);
  });

  test("handles fractional padding", () => {
    const element = {
      __computedStyle: {
        paddingLeft: "10.5px",
        paddingRight: "10.5px",
        paddingTop: "5.25px",
        paddingBottom: "5.25px",
      },
    } as unknown as HTMLElement;

    const padding = getPadding(element);
    expect(padding.horizontal).toBeCloseTo(21);
    expect(padding.vertical).toBeCloseTo(10.5);
  });
});

describe("calculateTerminalSize", () => {
  test("calculates cols and rows from container size", () => {
    const container = createMockContainer({
      clientWidth: 800,
      clientHeight: 400,
      measureRect: { width: 8, height: 16 },
    });

    const size = calculateTerminalSize(container);
    expect(size.cols).toBe(100); // 800 / 8
    expect(size.rows).toBe(25); // 400 / 16
    expect(size.cellWidth).toBe(8);
    expect(size.cellHeight).toBe(16);
  });

  test("accounts for container padding", () => {
    const container = createMockContainer({
      clientWidth: 820,
      clientHeight: 420,
      padding: { left: 10, right: 10, top: 10, bottom: 10 },
      measureRect: { width: 8, height: 16 },
    });

    const size = calculateTerminalSize(container);
    // Available: 820 - 20 = 800, 420 - 20 = 400
    expect(size.cols).toBe(100);
    expect(size.rows).toBe(25);
  });

  test("accounts for terminal element padding", () => {
    const container = createMockContainer({
      clientWidth: 840,
      clientHeight: 440,
      padding: { left: 10, right: 10, top: 10, bottom: 10 },
      terminalPadding: { left: 10, right: 10, top: 10, bottom: 10 },
      measureRect: { width: 8, height: 16 },
    });

    const size = calculateTerminalSize(container);
    // Available: 840 - 20 - 20 = 800, 440 - 20 - 20 = 400
    expect(size.cols).toBe(100);
    expect(size.rows).toBe(25);
  });

  test("returns -1 when measure element has no size", () => {
    const container = createMockContainer({
      clientWidth: 800,
      clientHeight: 400,
      measureRect: { width: 0, height: 0 },
    });

    const size = calculateTerminalSize(container);
    expect(size.cols).toBe(-1);
    expect(size.rows).toBe(-1);
    expect(size.cellWidth).toBe(0);
    expect(size.cellHeight).toBe(0);
  });

  test("returns -1 when container has no available space", () => {
    const container = createMockContainer({
      clientWidth: 20,
      clientHeight: 20,
      padding: { left: 10, right: 10, top: 10, bottom: 10 },
      measureRect: { width: 8, height: 16 },
    });

    const size = calculateTerminalSize(container);
    expect(size.cols).toBe(-1);
    expect(size.rows).toBe(-1);
  });

  test("enforces minimum cell dimensions", () => {
    // Cell width below MIN_CELL_WIDTH should use MIN_CELL_WIDTH
    const container = createMockContainer({
      clientWidth: 80,
      clientHeight: 160,
      measureRect: { width: 2, height: 4 }, // Below minimums
    });

    const size = calculateTerminalSize(container);
    // Should use MIN_CELL_WIDTH (4) and MIN_CELL_HEIGHT (8) for calculation
    expect(size.cols).toBe(20); // 80 / 4
    expect(size.rows).toBe(20); // 160 / 8
    // But report actual measured dimensions
    expect(size.cellWidth).toBe(2);
    expect(size.cellHeight).toBe(4);
  });

  test("clamps to minimum 1 col/row", () => {
    const container = createMockContainer({
      clientWidth: 2,
      clientHeight: 4,
      measureRect: { width: 8, height: 16 },
    });

    const size = calculateTerminalSize(container);
    // Would be 0 cols/rows, but clamped to 1
    expect(size.cols).toBe(1);
    expect(size.rows).toBe(1);
  });

  test("clamps to MAX_TERMINAL_SIZE", () => {
    const container = createMockContainer({
      clientWidth: 10000,
      clientHeight: 10000,
      measureRect: { width: 8, height: 16 },
    });

    const size = calculateTerminalSize(container);
    // Would be 1250 cols and 625 rows, clamped to MAX_TERMINAL_SIZE
    expect(size.cols).toBe(MAX_TERMINAL_SIZE);
    expect(size.rows).toBe(MAX_TERMINAL_SIZE);
  });

  test("floors fractional cols/rows", () => {
    const container = createMockContainer({
      clientWidth: 805, // 805 / 8 = 100.625
      clientHeight: 410, // 410 / 16 = 25.625
      measureRect: { width: 8, height: 16 },
    });

    const size = calculateTerminalSize(container);
    expect(size.cols).toBe(100);
    expect(size.rows).toBe(25);
  });
});

describe("constants", () => {
  test("MIN_CELL_WIDTH is reasonable", () => {
    expect(MIN_CELL_WIDTH).toBeGreaterThan(0);
    expect(MIN_CELL_WIDTH).toBeLessThanOrEqual(10);
  });

  test("MIN_CELL_HEIGHT is reasonable", () => {
    expect(MIN_CELL_HEIGHT).toBeGreaterThan(0);
    expect(MIN_CELL_HEIGHT).toBeLessThanOrEqual(20);
  });

  test("MAX_TERMINAL_SIZE is reasonable", () => {
    expect(MAX_TERMINAL_SIZE).toBeGreaterThanOrEqual(100);
    expect(MAX_TERMINAL_SIZE).toBeLessThanOrEqual(1000);
  });
});

describe("getOrCreateMeasureElement", () => {
  test("creates measure element if not exists", () => {
    let appendedChild: any = null;
    const container = {
      querySelector: () => null,
      appendChild: (child: any) => {
        appendedChild = child;
      },
    } as unknown as HTMLElement;

    getOrCreateMeasureElement(container);

    expect(appendedChild).not.toBeNull();
    expect(appendedChild.className).toBe("terminal-measure terminal-line");
    expect(appendedChild.textContent).toBe("X");
  });

  test("returns existing measure element", () => {
    const existingMeasure = { className: "terminal-measure" } as HTMLDivElement;
    const container = {
      querySelector: (selector: string) => {
        if (selector === ".terminal-measure") return existingMeasure;
        return null;
      },
      appendChild: () => {
        throw new Error("Should not append");
      },
    } as unknown as HTMLElement;

    const result = getOrCreateMeasureElement(container);
    expect(result).toBe(existingMeasure);
  });
});
