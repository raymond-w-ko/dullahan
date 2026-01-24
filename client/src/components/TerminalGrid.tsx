// Terminal grid layout component
// Renders panes from a window's layout tree or falls back to simple grid

import { h } from "preact";
import { useCallback } from "preact/hooks";
import { TerminalPane } from "./TerminalPane";
import { LayoutRenderer } from "./LayoutRenderer";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import { getWindow, getStore, getConnection } from "../store";
import type { LayoutNode } from "../../../protocol/schema/layout";

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
    return (
      <LayoutRenderer
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
