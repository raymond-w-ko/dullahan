import { useEffect, useState } from "preact/hooks";
import type { RefObject } from "preact";
import {
  calculateTerminalSize,
  getOrCreateMeasureElement,
  type TerminalSize,
} from "../terminal/dimensions";

export type TerminalDimensions = TerminalSize;

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

    // Ensure measurement element exists
    getOrCreateMeasureElement(container);

    const calculate = () => {
      const size = calculateTerminalSize(container);
      // Only update if measurement succeeded
      if (size.cols > 0 && size.rows > 0) {
        setDimensions(size);
      }
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
