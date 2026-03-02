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
import { ContextMenu } from "./ContextMenu";
import { useStoreSelector, shallowEqual } from "../hooks/useStoreSubscription";
import {
  initConnection,
  disconnectConnection,
  setSettingsOpen,
  setFullscreenPane,
  openLogoContextMenu,
  requestMaster,
} from "../store";
import * as config from "../config";

export function App() {
  const {
    connected,
    error,
    theme,
    settingsOpen,
    isMaster,
    masterId,
    activeWindowId,
    latency,
    fullscreenPaneId,
    layoutDividerEnabled,
  } = useStoreSelector(
    (store) => ({
      connected: store.connected,
      error: store.error,
      theme: store.theme,
      settingsOpen: store.settingsOpen,
      isMaster: store.isMaster,
      masterId: store.masterId,
      activeWindowId: store.activeWindowId,
      latency: store.latency,
      fullscreenPaneId: store.fullscreenPaneId,
      layoutDividerEnabled: store.layoutDividerEnabled,
    }),
    shallowEqual
  );

  // Initialize connection on mount
  useEffect(() => {
    config.ensureDefaults();
    config.applyToCSS();
    initConnection();
    return () => disconnectConnection();
  }, []);

  // Exit fullscreen on Escape key
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape" && fullscreenPaneId !== null) {
        e.preventDefault();
        setFullscreenPane(null);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [fullscreenPaneId]);

  // Sync resize-handle visibility with document class
  useEffect(() => {
    document.body.classList.toggle("layout-divider-enabled", layoutDividerEnabled);
    return () => {
      document.body.classList.remove("layout-divider-enabled");
    };
  }, [layoutDividerEnabled]);

  const handleLogoContextMenu = (e: MouseEvent) => {
    e.preventDefault();
    openLogoContextMenu(e.clientX, e.clientY);
  };

  return (
    <div class="app" data-theme={theme}>
      <ErrorBoundary>
        <main class="main">
          {error && <div class="error">Error: {error}</div>}
          <TerminalGrid windowId={activeWindowId} />
        </main>

        <SettingsModal isOpen={settingsOpen} onClose={() => setSettingsOpen(false)} />
        <LayoutPickerModal />
        <ContextMenu />
      </ErrorBoundary>

      <ToastContainer />
      <ClipboardBar />

      <aside class="bottombar">
        <div
          class="bottombar-logo"
          title="Dullahan (right-click for options)"
          onContextMenu={handleLogoContextMenu}
        >
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
        <span
          class={`bottombar-btn ${connected ? "bottombar-btn--connected" : "bottombar-btn--disconnected"}`}
          title={connected ? `Connected (${latency}ms latency)` : "Disconnected"}
        >
          {connected ? "\u25CF" : "\u25CB"}
          {connected && <span class="bottombar-latency">{latency.toFixed(1)}ms</span>}
        </span>
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
