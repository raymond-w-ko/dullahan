// Main application component
// Initializes connection and renders terminal grid

import { h } from "preact";
import { useEffect, useRef } from "preact/hooks";
import { ErrorBoundary } from "./ErrorBoundary";
import { TerminalGrid } from "./TerminalGrid";
import { SettingsModal } from "./SettingsModal";
import { WindowSwitcher } from "./WindowSwitcher";
import { ClipboardBar } from "./ClipboardBar";
import { LayoutPickerModal } from "./LayoutPickerModal";
import { ToastContainer } from "./ToastContainer";
import { ContextMenu } from "./ContextMenu";
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
  const dividerHoldTimeoutRef = useRef<number | null>(null);
  const dividerHoldAwaitingReleaseRef = useRef(false);
  const dividerHoldHeldRef = useRef(false);

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
      if (e.key === "Escape" && getStore().fullscreenPaneId !== null) {
        e.preventDefault();
        setFullscreenPane(null);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  // Toggle layout dividers after holding Meta/Ctrl for ~3 seconds
  useEffect(() => {
    const toggleDividers = () => {
      document.body.classList.toggle("layout-divider-enabled");
    };

    const clearTimer = () => {
      if (dividerHoldTimeoutRef.current !== null) {
        window.clearTimeout(dividerHoldTimeoutRef.current);
        dividerHoldTimeoutRef.current = null;
      }
    };

    const isModifierHeld = (e: KeyboardEvent) => e.metaKey || e.ctrlKey;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (!isModifierHeld(e)) return;

      dividerHoldHeldRef.current = true;
      if (
        dividerHoldAwaitingReleaseRef.current ||
        dividerHoldTimeoutRef.current !== null ||
        e.repeat
      ) {
        return;
      }

      dividerHoldTimeoutRef.current = window.setTimeout(() => {
        dividerHoldTimeoutRef.current = null;
        if (!dividerHoldHeldRef.current) return;
        toggleDividers();
        dividerHoldAwaitingReleaseRef.current = true;
      }, 2000);
    };

    const handleKeyUp = (e: KeyboardEvent) => {
      if (e.key !== "Meta" && e.key !== "Control") return;
      dividerHoldHeldRef.current = isModifierHeld(e);
      if (!dividerHoldHeldRef.current) {
        clearTimer();
        dividerHoldAwaitingReleaseRef.current = false;
      }
    };

    const handleBlur = () => {
      dividerHoldHeldRef.current = false;
      dividerHoldAwaitingReleaseRef.current = false;
      clearTimer();
    };

    window.addEventListener("keydown", handleKeyDown, true);
    window.addEventListener("keyup", handleKeyUp, true);
    window.addEventListener("blur", handleBlur);

    return () => {
      window.removeEventListener("keydown", handleKeyDown, true);
      window.removeEventListener("keyup", handleKeyUp, true);
      window.removeEventListener("blur", handleBlur);
      clearTimer();
    };
  }, []);

  const store = getStore();
  const { connected, error, theme, settingsOpen, isMaster, masterId, activeWindowId, latency } = store;

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
        <span
          class={`bottombar-btn ${connected ? "bottombar-btn--connected" : "bottombar-btn--disconnected"}`}
          title={connected ? `Connected (${latency}ms latency)` : "Disconnected"}
        >
          {connected ? "\u25CF" : "\u25CB"}
          {connected && latency > 0 && <span class="bottombar-latency">{latency}ms</span>}
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
