// Main application component
// Initializes connection and renders terminal grid

import { h } from "preact";
import { useEffect } from "preact/hooks";
import { ErrorBoundary } from "./ErrorBoundary";
import { TerminalGrid } from "./TerminalGrid";
import { SettingsModal } from "./SettingsModal";
import { WindowSwitcher } from "./WindowSwitcher";
import { ClipboardBar } from "./ClipboardBar";
import { LayoutPickerModal } from "./LayoutPickerModal";
import { ToastContainer } from "./ToastContainer";
import { ProgressBar } from "./ProgressBar";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import {
  getStore,
  initConnection,
  disconnectConnection,
  setSettingsOpen,
  setFullscreenPane,
  requestMaster,
} from "../store";
import * as config from "../config";

export function App() {
  useStoreSubscription();

  // Initialize connection on mount
  useEffect(() => {
    config.applyToCSS();
    initConnection();
    return () => disconnectConnection();
  }, []);

  // Exit fullscreen on Escape key
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape" && getStore().fullscreenPaneId !== null) {
        e.preventDefault();
        setFullscreenPane(null);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  const store = getStore();
  const { connected, error, theme, settingsOpen, isMaster, masterId, activeWindowId } = store;

  return (
    <div class="app" data-theme={theme}>
      <ProgressBar />
      <ErrorBoundary>
        <main class="main">
          {error && <div class="error">Error: {error}</div>}
          <TerminalGrid windowId={activeWindowId} />
        </main>

        <SettingsModal isOpen={settingsOpen} onClose={() => setSettingsOpen(false)} />
        <LayoutPickerModal />
      </ErrorBoundary>

      <ToastContainer />
      <ClipboardBar />

      <aside class="bottombar">
        <div class="bottombar-logo" title="Dullahan">
          D
        </div>
        <WindowSwitcher />
        <div class="bottombar-spacer" />
        <button
          class={`bottombar-btn ${isMaster ? "bottombar-btn--master" : masterId ? "bottombar-btn--slave" : ""}`}
          onClick={() => !isMaster && requestMaster()}
          title={isMaster ? "You are master" : masterId ? "Click to become master" : "No master - click to claim"}
        >
          {isMaster ? "\u2605" : "\u2606"}
        </button>
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
    </div>
  );
}
