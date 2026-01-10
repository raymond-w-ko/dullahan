// Main application component
// Initializes connection and renders terminal grid

import { h } from "preact";
import { useState, useEffect } from "preact/hooks";
import { TerminalGrid } from "./TerminalGrid";
import { SettingsModal } from "./SettingsModal";
import {
  getStore,
  subscribe,
  initConnection,
  disconnectConnection,
  setSettingsOpen,
} from "../store";
import * as config from "../config";

export function App() {
  const [, forceUpdate] = useState(0);

  // Subscribe to store changes
  useEffect(() => {
    return subscribe(() => forceUpdate((n) => n + 1));
  }, []);

  // Initialize connection on mount
  useEffect(() => {
    config.applyToCSS();
    initConnection();
    return () => disconnectConnection();
  }, []);

  const store = getStore();
  const { connected, error, theme, settingsOpen } = store;

  return (
    <div class="app" data-theme={theme}>
      <aside class="bottombar">
        <div class="bottombar-logo" title="Dullahan">
          D
        </div>
        <div class="bottombar-spacer" />
        <button
          class={`bottombar-btn ${connected ? "bottombar-btn--connected" : "bottombar-btn--disconnected"}`}
          title={connected ? "Connected" : "Disconnected"}
        >
          {connected ? "\u25CF" : "\u25CB"}
        </button>
        <button
          class="bottombar-btn"
          onClick={() => setSettingsOpen(true)}
          title="Settings"
        >
          {"\u2699"}
        </button>
      </aside>

      <main class="main">
        {error && <div class="error">Error: {error}</div>}
        <TerminalGrid windowId={0} />
      </main>

      <SettingsModal isOpen={settingsOpen} onClose={() => setSettingsOpen(false)} />
    </div>
  );
}
