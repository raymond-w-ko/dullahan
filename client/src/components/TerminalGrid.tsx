// Terminal grid layout component
// Renders panes from a window's layout tree or falls back to simple grid

import { h } from "preact";
import { useCallback, useMemo } from "preact/hooks";
import { TerminalPane } from "./TerminalPane";
import { LayoutRenderer } from "./LayoutRenderer";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import { getWindow, getStore, getConnection } from "../store";
import type { LayoutNode } from "../../../protocol/schema/layout";

/** Generate a key from layout dimensions and window ID to force re-render on changes */
function getLayoutKey(windowId: number, nodes: LayoutNode[]): string {
  const parts: string[] = [`w${windowId}`];
  function collect(ns: LayoutNode[]) {
    for (const n of ns) {
      parts.push(`${n.width.toFixed(1)}-${n.height.toFixed(1)}`);
      if (n.type === "container" && n.children) {
        collect(n.children);
      }
    }
  }
  collect(nodes);
  return parts.join(":");
}

export interface TerminalGridProps {
  windowId: number;
}

export function TerminalGrid({ windowId }: TerminalGridProps) {
  useStoreSubscription();

  const store = getStore();
  const window = getWindow(windowId);

  if (!window) {
    return (
      <div class="not-found">
        <div class="not-found-icon">⚠</div>
        <div class="not-found-title">Window Not Found</div>
        <div class="not-found-detail">Window {windowId} does not exist</div>
      </div>
    );
  }

  // Check if a pane in this window is fullscreen
  const { fullscreenPaneId } = store;
  if (fullscreenPaneId !== null && window.paneIds.includes(fullscreenPaneId)) {
    return (
      <div class="terminal-grid terminal-grid--fullscreen">
        <TerminalPane key={fullscreenPaneId} paneId={fullscreenPaneId} windowId={windowId} />
      </div>
    );
  }

  // Callback to send resize_layout message to server
  const handleResizeLayout = useCallback(
    (nodes: LayoutNode[]) => {
      const connection = getConnection();
      if (connection) {
        connection.resizeLayout(windowId, nodes);
      }
    },
    [windowId]
  );

  // Use LayoutRenderer if window has a layout tree
  if (window.layout?.nodes) {
    // Key includes windowId and dimensions to force re-render when switching windows or resetting layout
    const layoutKey = getLayoutKey(windowId, window.layout.nodes);
    return (
      <LayoutRenderer
        key={layoutKey}
        nodes={window.layout.nodes}
        windowId={windowId}
        onResizeLayout={handleResizeLayout}
      />
    );
  }

  // Fallback: simple grid layout (legacy)
  const paneCount = window.paneIds.length;
  const gridStyle = {
    gridTemplateColumns: `repeat(${paneCount}, 1fr)`,
  };

  return (
    <div class="terminal-grid" style={gridStyle}>
      {window.paneIds.map((paneId) => (
        <TerminalPane key={paneId} paneId={paneId} windowId={windowId} />
      ))}
    </div>
  );
}
