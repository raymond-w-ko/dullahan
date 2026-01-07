import { useEffect, useState, useRef } from "preact/hooks";
import type { RefObject } from "preact";

export interface TerminalDimensions {
  cols: number;
  rows: number;
  cellWidth: number;
  cellHeight: number;
}

/**
 * Hook to calculate visible terminal dimensions based on container size and font metrics.
 * Uses ResizeObserver to update on resize.
 */
export function useTerminalDimensions(
  containerRef: RefObject<HTMLElement>
): TerminalDimensions {
  const [dimensions, setDimensions] = useState<TerminalDimensions>({
    cols: 80,
    rows: 24,
    cellWidth: 0,
    cellHeight: 0,
  });
  
  const measureRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // Create hidden measurement element that matches terminal line styling
    const measure = document.createElement('div');
    measure.className = 'terminal-line'; // Use same class as actual lines
    measure.style.cssText = `
      position: absolute;
      visibility: hidden;
      pointer-events: none;
    `;
    measure.textContent = 'X'; // Single character to measure width
    container.appendChild(measure);
    measureRef.current = measure;

    const calculate = () => {
      if (!measure || !container) return;

      // Get cell dimensions from the measurement element
      // Width: measure single character
      // Height: use the line's actual height (includes line-height)
      const rect = measure.getBoundingClientRect();
      const cellWidth = rect.width; // Width of 'X'
      const cellHeight = rect.height; // Height of line (1.2em)

      if (cellWidth === 0 || cellHeight === 0) return;

      // Get container dimensions (minus padding)
      const style = getComputedStyle(container);
      const paddingX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
      const paddingY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
      const availableWidth = container.clientWidth - paddingX;
      const availableHeight = container.clientHeight - paddingY;

      // Calculate dimensions, clamping to reasonable bounds
      // Min cellHeight of 8px prevents division by tiny values before fonts load
      const safeCellWidth = Math.max(cellWidth, 4);
      const safeCellHeight = Math.max(cellHeight, 8);
      
      const cols = Math.floor(availableWidth / safeCellWidth);
      const rows = Math.floor(availableHeight / safeCellHeight);

      // Clamp to reasonable terminal sizes (1-500 cols/rows)
      setDimensions({
        cols: Math.max(1, Math.min(500, cols)),
        rows: Math.max(1, Math.min(500, rows)),
        cellWidth,
        cellHeight,
      });
    };

    // Initial calculation
    calculate();

    // Observe resize
    const observer = new ResizeObserver(() => {
      calculate();
    });
    observer.observe(container);

    // Also recalculate when fonts load
    document.fonts.ready.then(calculate);

    return () => {
      observer.disconnect();
      if (measureRef.current && container.contains(measureRef.current)) {
        container.removeChild(measureRef.current);
      }
    };
  }, [containerRef]);

  return dimensions;
}
