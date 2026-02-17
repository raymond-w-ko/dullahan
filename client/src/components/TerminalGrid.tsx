// Terminal grid layout component
// Renders panes from a window's layout tree or falls back to simple grid

import { h } from "preact";
import { useCallback } from "preact/hooks";
import { TerminalPane } from "./TerminalPane";
import { LayoutRenderer } from "./LayoutRenderer";
import { useStoreSelector, shallowEqual } from "../hooks/useStoreSubscription";
import { getConnection } from "../store";
import type { LayoutNode } from "../../../protocol/schema/layout";

/** Generate a stable key from layout topology (not dimensions) and window ID. */
function getLayoutKey(windowId: number, nodes: LayoutNode[]): string {
  const parts: string[] = [`w${windowId}`];
  function collect(ns: LayoutNode[]) {
    for (const n of ns) {
      if (n.type === "pane") {
        parts.push(`p:${n.paneId ?? "x"}`);
      } else {
        parts.push(`c:${n.children.length}`);
      }
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
  const { window, fullscreenPaneId } = useStoreSelector(
    (store) => ({
      window: store.windows.get(windowId),
      fullscreenPaneId: store.fullscreenPaneId,
    }),
    shallowEqual
  );

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
  if (fullscreenPaneId !== null && window.paneIds.includes(fullscreenPaneId)) {
    return (
      <div class="terminal-grid terminal-grid--fullscreen">
        <TerminalPane key={`${windowId}-${fullscreenPaneId}`} paneId={fullscreenPaneId} windowId={windowId} />
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
    // Key includes window + topology to avoid remounting on size-only updates.
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
        <TerminalPane key={`${windowId}-${paneId}`} paneId={paneId} windowId={windowId} />
      ))}
    </div>
  );
}
