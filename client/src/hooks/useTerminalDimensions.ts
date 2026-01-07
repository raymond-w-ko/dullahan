import { useEffect, useState } from "preact/hooks";
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
 * Uses a persistent .terminal-measure element for efficiency and debuggability.
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

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // Find or create persistent measurement element
    let measure = container.querySelector('.terminal-measure') as HTMLDivElement | null;
    if (!measure) {
      measure = document.createElement('div');
      measure.className = 'terminal-measure terminal-line';
      measure.textContent = 'X';
      container.appendChild(measure);
    }

    const calculate = () => {
      if (!measure || !container) return;

      const rect = measure.getBoundingClientRect();
      const cellWidth = rect.width;
      const cellHeight = rect.height;

      if (cellWidth === 0 || cellHeight === 0) return;

      // Get container dimensions (minus padding)
      const style = getComputedStyle(container);
      const paddingX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
      const paddingY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
      const availableWidth = container.clientWidth - paddingX;
      const availableHeight = container.clientHeight - paddingY;

      const safeCellWidth = Math.max(cellWidth, 4);
      const safeCellHeight = Math.max(cellHeight, 8);

      const cols = Math.floor(availableWidth / safeCellWidth);
      const rows = Math.floor(availableHeight / safeCellHeight);

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
      // Don't remove the measure element - it's persistent and may be shared
    };
  }, [containerRef]);

  return dimensions;
}
