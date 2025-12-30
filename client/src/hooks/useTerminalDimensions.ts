import { useEffect, useState, useRef, RefObject } from "preact/hooks";

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
  
  const measureRef = useRef<HTMLSpanElement | null>(null);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // Create hidden measurement element
    const measure = document.createElement('span');
    measure.style.cssText = `
      position: absolute;
      visibility: hidden;
      white-space: pre;
      font: inherit;
    `;
    measure.textContent = 'X'; // Single character to measure
    container.appendChild(measure);
    measureRef.current = measure;

    const calculate = () => {
      if (!measure || !container) return;

      // Get cell dimensions from the measurement element
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

      const cols = Math.floor(availableWidth / cellWidth);
      const rows = Math.floor(availableHeight / cellHeight);

      setDimensions({
        cols: Math.max(1, cols),
        rows: Math.max(1, rows),
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
