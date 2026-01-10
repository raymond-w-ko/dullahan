// Terminal grid layout component
// Renders panes from a window's pane list

import { h } from "preact";
import { useState, useEffect } from "preact/hooks";
import { TerminalPane } from "./TerminalPane";
import { getWindow, subscribe } from "../store";

export interface TerminalGridProps {
  windowId: number;
}

export function TerminalGrid({ windowId }: TerminalGridProps) {
  const [, forceUpdate] = useState(0);

  // Subscribe to store changes
  useEffect(() => {
    return subscribe(() => forceUpdate((n) => n + 1));
  }, []);

  const window = getWindow(windowId);

  if (!window) {
    return <div class="terminal-grid terminal-grid--error">Window {windowId} not found</div>;
  }

  return (
    <div class="terminal-grid">
      {window.paneIds.map((paneId) => (
        <TerminalPane key={paneId} paneId={paneId} />
      ))}
    </div>
  );
}
