// Terminal pane component
// Wraps TerminalView with titlebar and handles pane-specific state

import { h } from "preact";
import { useEffect, useRef, useCallback } from "preact/hooks";
import { TerminalView } from "./TerminalView";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import {
  getStore,
  getPane,
  getConnection,
  setPaneDimensions,
  setBellActive,
  setFocusedPane,
} from "../store";
import { getBellFeatures } from "../config";

export interface TerminalPaneProps {
  paneId: number;
}

export function TerminalPane({ paneId }: TerminalPaneProps) {
  useStoreSubscription();
  const terminalRef = useRef<HTMLDivElement>(null);

  const store = getStore();
  const pane = getPane(paneId);
  const connection = getConnection();

  if (!pane) {
    return <div class="terminal-pane terminal-pane--error">Pane {paneId} not found</div>;
  }

  const { snapshot, syncStats, isReadOnly, title, dimensions } = pane;
  const { connected, bellActive, cursorStyle, cursorColor, cursorText, cursorBlink, focusedPaneId, dimensionVersion } = store;

  // This pane has bell if it's focused and bell is active
  const hasBell = bellActive && focusedPaneId === paneId && !isReadOnly;

  // Calculate and report dimensions
  useEffect(() => {
    const container = terminalRef.current;
    if (!container || !connection || isReadOnly) return;

    const calculate = () => {
      const size = connection.calculatePaneSize(container);
      if (size.cols > 0 && size.rows > 0) {
        // Update store and notify server
        setPaneDimensions(paneId, size.cols, size.rows);
        connection.setPaneSize(paneId, size.cols, size.rows);
      }
    };

    // Initial calculation
    calculate();

    // Delayed recalculation - handles cases where layout hasn't settled yet
    // (new windows, varying layouts, initial connection)
    const delayedTimer = window.setTimeout(calculate, 100);

    // Observe resize
    const observer = new ResizeObserver(() => {
      calculate();
    });
    observer.observe(container);

    // Also recalculate when fonts load
    document.fonts.ready.then(calculate);

    return () => {
      window.clearTimeout(delayedTimer);
      observer.disconnect();
    };
  }, [connection, paneId, isReadOnly, dimensionVersion]);

  // Handle click on pane to focus it
  const handlePaneClick = useCallback(() => {
    if (!isReadOnly && connection?.isConnected) {
      connection.sendFocus(paneId);
      setFocusedPane(paneId);
    }
  }, [isReadOnly, connection, paneId]);

  // Dismiss bell on key input
  const handleKeyInput = useCallback(() => {
    setBellActive(false);
  }, []);

  const displayDims = dimensions.cols > 0 ? dimensions : { cols: 80, rows: 24 };
  const isFocused = focusedPaneId === paneId;

  return (
    <div
      class={`terminal-pane${hasBell ? " bell-active" : ""}${isReadOnly ? " terminal-pane--readonly" : ""}${isFocused ? " terminal-pane--focused" : ""}`}
      onClick={handlePaneClick}
    >
      <div class="terminal-titlebar">
        <span
          class="terminal-title"
          onClick={hasBell ? handleKeyInput : undefined}
          style={{ cursor: hasBell ? "pointer" : undefined }}
        >
          {hasBell && getBellFeatures().title ? "\u{1F514} " : ""}
          {title}
        </span>
        {syncStats && (
          <span
            class="terminal-sync-stats"
            title={`Generation: ${syncStats.gen}, Deltas: ${syncStats.deltas}, Resyncs: ${syncStats.resyncs}`}
          >
            {"\u0394"}{syncStats.deltas} {"\u27F3"}{syncStats.resyncs}
          </span>
        )}
        <span
          class="terminal-size"
          title={`Server: ${snapshot?.cols}\u00D7${snapshot?.rows}, Visible: ${displayDims.cols}\u00D7${displayDims.rows}`}
        >
          {snapshot ? `${displayDims.cols}\u00D7${displayDims.rows}` : "\u2014"}
        </span>
      </div>
      <div class="terminal-container" ref={terminalRef}>
        {snapshot ? (
          <TerminalView
            paneId={paneId}
            snapshot={snapshot}
            cursorStyle={cursorStyle}
            cursorColor={cursorColor}
            cursorText={cursorText}
            cursorBlink={cursorBlink}
            isReadOnly={isReadOnly}
            isActive={focusedPaneId === paneId}
            onKeyInput={isReadOnly ? undefined : handleKeyInput}
            connection={connection}
          />
        ) : (
          <div class="terminal terminal--empty">
            {connected ? "Waiting..." : "Connecting..."}
          </div>
        )}
      </div>
    </div>
  );
}
