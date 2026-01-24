// Layout divider component for pane resizing
// Renders a draggable divider between sibling panes

import { h } from "preact";
import { useState, useCallback, useEffect, useRef } from "preact/hooks";

export interface LayoutDividerProps {
  /** Direction of the split (horizontal = side by side, vertical = stacked) */
  direction: "horizontal" | "vertical";
  /** Called during drag with the delta in percentage points */
  onDrag: (deltaPercent: number) => void;
  /** Called when drag ends */
  onDragEnd: () => void;
  /** Reference to the container element for measuring total size */
  containerRef: { current: HTMLElement | null };
}

/**
 * LayoutDivider - draggable divider between panes
 *
 * Horizontal splits have horizontal dividers (drag left/right, col-resize cursor)
 * Vertical splits have vertical dividers (drag up/down, row-resize cursor)
 */
export function LayoutDivider({
  direction,
  onDrag,
  onDragEnd,
  containerRef,
}: LayoutDividerProps) {
  const [isDragging, setIsDragging] = useState(false);
  const startPosRef = useRef(0);
  const lastDeltaRef = useRef(0);

  // Handle mouse down - start drag
  const handleMouseDown = useCallback(
    (e: MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();

      setIsDragging(true);
      startPosRef.current = direction === "horizontal" ? e.clientX : e.clientY;
      lastDeltaRef.current = 0;

      // Add body class for cursor override
      document.body.classList.add(
        direction === "horizontal"
          ? "layout-resizing-horizontal"
          : "layout-resizing-vertical"
      );
    },
    [direction]
  );

  // Handle mouse move during drag
  useEffect(() => {
    if (!isDragging) return;

    const handleMouseMove = (e: MouseEvent) => {
      if (!containerRef.current) return;

      const container = containerRef.current;
      const rect = container.getBoundingClientRect();

      // Get container size in the relevant dimension
      const containerSize =
        direction === "horizontal" ? rect.width : rect.height;

      // Calculate pixel delta from start position
      const currentPos =
        direction === "horizontal" ? e.clientX : e.clientY;
      const pixelDelta = currentPos - startPosRef.current;

      // Convert to percentage
      const percentDelta = (pixelDelta / containerSize) * 100;

      // Only call onDrag if delta changed significantly (throttle to ~60fps)
      if (Math.abs(percentDelta - lastDeltaRef.current) > 0.1) {
        lastDeltaRef.current = percentDelta;
        onDrag(percentDelta);
      }
    };

    const handleMouseUp = () => {
      setIsDragging(false);

      // Remove body class
      document.body.classList.remove(
        "layout-resizing-horizontal",
        "layout-resizing-vertical"
      );

      onDragEnd();
    };

    // Use capture to ensure we get events even if mouse leaves the divider
    document.addEventListener("mousemove", handleMouseMove, { capture: true });
    document.addEventListener("mouseup", handleMouseUp, { capture: true });

    return () => {
      document.removeEventListener("mousemove", handleMouseMove, {
        capture: true,
      });
      document.removeEventListener("mouseup", handleMouseUp, { capture: true });
    };
  }, [isDragging, direction, containerRef, onDrag, onDragEnd]);

  const className = [
    "layout-divider",
    direction === "horizontal"
      ? "layout-divider--horizontal"
      : "layout-divider--vertical",
    isDragging ? "layout-divider--dragging" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <div
      class={className}
      onMouseDown={handleMouseDown}
    />
  );
}
