// Recursive layout renderer component
// Renders layout tree using flexbox CSS with draggable dividers for resizing

import { h, Fragment } from "preact";
import { useRef, useState, useCallback } from "preact/hooks";
import { TerminalPane } from "./TerminalPane";
import { LayoutDivider } from "./LayoutDivider";
import type { LayoutNode, LayoutContainer, LayoutPane } from "../../../protocol/schema/layout";
import { isContainer, isPane } from "../../../protocol/schema/layout";

export interface LayoutRendererProps {
  nodes: LayoutNode[];
  level?: number; // Nesting level (0 = root, horizontal)
  windowId?: number; // Window ID for pane context menus
  /** Callback when layout is resized by dragging dividers */
  onResizeLayout?: (nodes: LayoutNode[]) => void;
}

/** Deep clone layout nodes */
function cloneNodes(nodes: LayoutNode[]): LayoutNode[] {
  return nodes.map((node) => {
    if (isPane(node)) {
      return { ...node };
    } else {
      return {
        ...node,
        children: cloneNodes(node.children),
      };
    }
  });
}

/**
 * Render nodes with dividers between them
 */
function NodesWithDividers({
  nodes,
  level,
  windowId,
  containerRef,
  onResize,
  onDragEnd: parentDragEnd,
  onResizeLayout,
}: {
  nodes: LayoutNode[];
  level: number;
  windowId?: number;
  containerRef: { current: HTMLElement | null };
  onResize: (index: number, deltaPercent: number) => void;
  onDragEnd?: () => void;
  onResizeLayout?: (nodes: LayoutNode[]) => void;
}) {
  const isHorizontal = level % 2 === 0;
  const direction = isHorizontal ? "horizontal" : "vertical";

  // Track which divider is being dragged
  const [activeDivider, setActiveDivider] = useState<number | null>(null);
  const startSizesRef = useRef<{ left: number; right: number } | null>(null);

  const handleDrag = useCallback(
    (dividerIndex: number, deltaPercent: number) => {
      // Store starting sizes on first drag
      if (startSizesRef.current === null) {
        const leftNode = nodes[dividerIndex];
        const rightNode = nodes[dividerIndex + 1];
        if (!leftNode || !rightNode) return;

        const leftSize = isHorizontal ? leftNode.width : leftNode.height;
        const rightSize = isHorizontal ? rightNode.width : rightNode.height;
        startSizesRef.current = { left: leftSize, right: rightSize };
      }

      setActiveDivider(dividerIndex);
      onResize(dividerIndex, deltaPercent);
    },
    [nodes, isHorizontal, onResize]
  );

  const handleDragEnd = useCallback(() => {
    setActiveDivider(null);
    startSizesRef.current = null;
    // Notify parent that drag ended so it can send to server
    if (parentDragEnd) {
      parentDragEnd();
    }
  }, [parentDragEnd]);

  const elements: h.JSX.Element[] = [];

  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i]!;

    // Render the node - use paneId in key when available to ensure proper remounting
    const nodeKey = isPane(node) && node.paneId !== undefined
      ? `pane-${node.paneId}`
      : `node-${i}`;
    elements.push(
      <NodeRenderer
        key={nodeKey}
        node={node}
        level={level}
        index={i}
        siblings={nodes}
        windowId={windowId}
        onResizeLayout={onResizeLayout}
      />
    );

    // Add divider after each node except the last
    if (i < nodes.length - 1) {
      elements.push(
        <LayoutDivider
          key={`divider-${i}`}
          direction={direction}
          containerRef={containerRef}
          onDrag={(delta) => handleDrag(i, delta)}
          onDragEnd={handleDragEnd}
        />
      );
    }
  }

  return <>{elements}</>;
}

/**
 * Render a single layout node (container or pane)
 */
function NodeRenderer({
  node,
  level,
  index,
  siblings,
  windowId,
  onResizeLayout,
}: {
  node: LayoutNode;
  level: number;
  index: number;
  siblings: LayoutNode[];
  windowId?: number;
  onResizeLayout?: (nodes: LayoutNode[]) => void;
}): h.JSX.Element {
  // Even levels = horizontal, odd levels = vertical
  const isHorizontal = level % 2 === 0;

  // Use flex-basis for sizing: in horizontal layout it controls width, in vertical it controls height
  const size = isHorizontal ? node.width : node.height;
  const style = { flex: `0 0 ${size}%` };

  const handleResizeLayout = useCallback(
    (childNodes: LayoutNode[]) => {
      if (!onResizeLayout) return;
      const updated = cloneNodes(siblings);
      const target = updated[index];
      if (!target) {
        return;
      }
      if (isContainer(target)) {
        target.children = childNodes;
      } else {
        return;
      }
      onResizeLayout(updated);
    },
    [siblings, index, onResizeLayout]
  );

  if (isPane(node)) {
    // Pane node - render terminal
    // Key includes windowId to force complete remount when switching windows
    return (
      <div
        key={`pane-${node.paneId ?? index}`}
        class="layout-pane"
        style={style}
      >
        {node.paneId !== undefined ? (
          <TerminalPane key={`${windowId}-${node.paneId}`} paneId={node.paneId} windowId={windowId} />
        ) : (
          <div class="terminal--empty">
            <span class="terminal-placeholder-text">No pane assigned</span>
          </div>
        )}
      </div>
    );
  }

  if (isContainer(node)) {
    // Container node - recurse into children
    // Children are at next level (alternating direction)
    const childLevel = level + 1;
    const childIsHorizontal = childLevel % 2 === 0;
    const containerClass = childIsHorizontal
      ? "layout-container layout-horizontal"
      : "layout-container layout-vertical";

    return (
      <ContainerRenderer
        key={`container-${index}`}
        node={node}
        level={level}
        childLevel={childLevel}
        containerClass={containerClass}
        style={style}
        windowId={windowId}
        onResizeLayout={handleResizeLayout}
      />
    );
  }

  // Unknown node type
  return <Fragment key={`unknown-${index}`} />;
}

/**
 * Container renderer with resize support
 */
function ContainerRenderer({
  node,
  level,
  childLevel,
  containerClass,
  style,
  windowId,
  onResizeLayout,
}: {
  node: LayoutContainer;
  level: number;
  childLevel: number;
  containerClass: string;
  style: { flex: string };
  windowId?: number;
  onResizeLayout?: (nodes: LayoutNode[]) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [localNodes, setLocalNodes] = useState<LayoutNode[] | null>(null);
  const startSizesRef = useRef<number[] | null>(null);

  // Use local nodes during drag, otherwise use prop nodes
  const displayNodes = localNodes ?? node.children;
  const childIsHorizontal = childLevel % 2 === 0;

  const handleResize = useCallback(
    (dividerIndex: number, deltaPercent: number) => {
      // Initialize start sizes on first drag
      if (startSizesRef.current === null) {
        startSizesRef.current = node.children.map((n) =>
          childIsHorizontal ? n.width : n.height
        );
        setLocalNodes(cloneNodes(node.children));
      }

      const startSizes = startSizesRef.current;
      if (!startSizes) return;

      // Calculate new sizes
      const leftStart = startSizes[dividerIndex]!;
      const rightStart = startSizes[dividerIndex + 1]!;

      // Clamp delta to keep both panes at minimum 5%
      const minSize = 5;
      const maxDelta = leftStart - minSize;
      const minDelta = -(rightStart - minSize);
      const clampedDelta = Math.max(minDelta, Math.min(maxDelta, deltaPercent));

      const newLeftSize = leftStart + clampedDelta;
      const newRightSize = rightStart - clampedDelta;

      // Update local nodes
      setLocalNodes((prev) => {
        if (!prev) return null;
        const updated = cloneNodes(prev);
        const leftNode = updated[dividerIndex]!;
        const rightNode = updated[dividerIndex + 1]!;

        if (childIsHorizontal) {
          if (isPane(leftNode)) (leftNode as LayoutPane).width = newLeftSize;
          else (leftNode as LayoutContainer).width = newLeftSize;
          if (isPane(rightNode)) (rightNode as LayoutPane).width = newRightSize;
          else (rightNode as LayoutContainer).width = newRightSize;
        } else {
          if (isPane(leftNode)) (leftNode as LayoutPane).height = newLeftSize;
          else (leftNode as LayoutContainer).height = newLeftSize;
          if (isPane(rightNode)) (rightNode as LayoutPane).height = newRightSize;
          else (rightNode as LayoutContainer).height = newRightSize;
        }

        return updated;
      });
    },
    [node.children, childIsHorizontal]
  );

  const handleDragEnd = useCallback(() => {
    if (localNodes && onResizeLayout) {
      // Create a new full layout tree with the updated container
      onResizeLayout(localNodes);
    }
    setLocalNodes(null);
    startSizesRef.current = null;
  }, [localNodes, onResizeLayout]);

  return (
    <div ref={containerRef} class={containerClass} style={style}>
      <NodesWithDividers
        nodes={displayNodes}
        level={childLevel}
        windowId={windowId}
        containerRef={containerRef}
        onResize={handleResize}
        onDragEnd={handleDragEnd}
        onResizeLayout={onResizeLayout}
      />
    </div>
  );
}

/**
 * LayoutRenderer - recursively renders a layout tree with resizable dividers
 *
 * Layout direction alternates by nesting level:
 * - Level 0 (root): horizontal (children side by side)
 * - Level 1: vertical (children stacked)
 * - Level 2: horizontal again
 * - etc.
 */
export function LayoutRenderer({
  nodes,
  level = 0,
  windowId,
  onResizeLayout,
}: LayoutRendererProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [localNodes, setLocalNodes] = useState<LayoutNode[] | null>(null);
  const startSizesRef = useRef<number[] | null>(null);

  // Root level determines initial direction
  const isHorizontal = level % 2 === 0;
  const rootClass = isHorizontal
    ? "layout-root layout-horizontal"
    : "layout-root layout-vertical";

  // Use local nodes during drag, otherwise use prop nodes
  const displayNodes = localNodes ?? nodes;

  const handleResize = useCallback(
    (dividerIndex: number, deltaPercent: number) => {
      // Initialize start sizes on first drag
      if (startSizesRef.current === null) {
        startSizesRef.current = nodes.map((n) =>
          isHorizontal ? n.width : n.height
        );
        setLocalNodes(cloneNodes(nodes));
      }

      const startSizes = startSizesRef.current;
      if (!startSizes) return;

      // Calculate new sizes
      const leftStart = startSizes[dividerIndex]!;
      const rightStart = startSizes[dividerIndex + 1]!;

      // Clamp delta to keep both panes at minimum 5%
      const minSize = 5;
      const maxDelta = leftStart - minSize;
      const minDelta = -(rightStart - minSize);
      const clampedDelta = Math.max(minDelta, Math.min(maxDelta, deltaPercent));

      const newLeftSize = leftStart + clampedDelta;
      const newRightSize = rightStart - clampedDelta;

      // Update local nodes
      setLocalNodes((prev) => {
        if (!prev) return null;
        const updated = cloneNodes(prev);
        const leftNode = updated[dividerIndex]!;
        const rightNode = updated[dividerIndex + 1]!;

        if (isHorizontal) {
          if (isPane(leftNode)) (leftNode as LayoutPane).width = newLeftSize;
          else (leftNode as LayoutContainer).width = newLeftSize;
          if (isPane(rightNode)) (rightNode as LayoutPane).width = newRightSize;
          else (rightNode as LayoutContainer).width = newRightSize;
        } else {
          if (isPane(leftNode)) (leftNode as LayoutPane).height = newLeftSize;
          else (leftNode as LayoutContainer).height = newLeftSize;
          if (isPane(rightNode)) (rightNode as LayoutPane).height = newRightSize;
          else (rightNode as LayoutContainer).height = newRightSize;
        }

        return updated;
      });
    },
    [nodes, isHorizontal]
  );

  const handleDragEnd = useCallback(() => {
    if (localNodes && onResizeLayout) {
      onResizeLayout(localNodes);
    }
    setLocalNodes(null);
    startSizesRef.current = null;
  }, [localNodes, onResizeLayout]);

  return (
    <div ref={containerRef} class={rootClass}>
      <NodesWithDividers
        nodes={displayNodes}
        level={level}
        windowId={windowId}
        containerRef={containerRef}
        onResize={handleResize}
        onDragEnd={handleDragEnd}
        onResizeLayout={onResizeLayout}
      />
    </div>
  );
}
