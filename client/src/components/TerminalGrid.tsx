// Terminal grid layout component
// Renders panes from a window's layout tree or falls back to simple grid

import { h } from "preact";
import { TerminalPane } from "./TerminalPane";
import { LayoutRenderer } from "./LayoutRenderer";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import { getWindow } from "../store";

export interface TerminalGridProps {
  windowId: number;
}

export function TerminalGrid({ windowId }: TerminalGridProps) {
  useStoreSubscription();

  const window = getWindow(windowId);

  if (!window) {
    return <div class="terminal-grid terminal-grid--error">Window {windowId} not found</div>;
  }

  // Use LayoutRenderer if window has a layout tree
  if (window.layout?.nodes) {
    return <LayoutRenderer nodes={window.layout.nodes} />;
  }

  // Fallback: simple grid layout (legacy)
  const paneCount = window.paneIds.length;
  const gridStyle = {
    gridTemplateColumns: `repeat(${paneCount}, 1fr)`,
  };

  return (
    <div class="terminal-grid" style={gridStyle}>
      {window.paneIds.map((paneId) => (
        <TerminalPane key={paneId} paneId={paneId} />
      ))}
    </div>
  );
}
