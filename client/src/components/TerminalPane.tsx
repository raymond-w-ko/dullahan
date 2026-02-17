// Terminal pane component
// Wraps TerminalView with titlebar and handles pane-specific state

import { h } from "preact";
import { useEffect, useRef, useCallback } from "preact/hooks";
import { TerminalView } from "./TerminalView";
import { ProgressBar } from "./ProgressBar";
import {
  useStoreSelector,
  usePaneStoreSelector,
  shallowEqual,
} from "../hooks/useStoreSubscription";
import {
  setPaneDimensions,
  setBellActive,
  setFocusedPane,
  openPaneContextMenu,
} from "../store";
import { getBellFeatures } from "../config";

export interface TerminalPaneProps {
  paneId: number;
  windowId?: number; // Optional for backward compatibility (fullscreen, legacy grid)
}

export function TerminalPane({ paneId, windowId }: TerminalPaneProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const {
    paneExists,
    snapshot,
    syncDeltas,
    syncResyncs,
    syncGen,
    deltaChangedRowIds,
    deltaGen,
    isReadOnly,
    title,
    dimensions,
  } = usePaneStoreSelector(
    paneId,
    (store) => {
      const pane = store.panes.get(paneId);
      return {
        paneExists: pane !== undefined,
        snapshot: pane?.snapshot ?? null,
        syncDeltas: pane?.syncStats.deltas ?? 0,
        syncResyncs: pane?.syncStats.resyncs ?? 0,
        syncGen: pane?.syncStats.gen ?? 0,
        deltaChangedRowIds: pane?.deltaChangedRowIds ?? [],
        deltaGen: pane?.deltaGen ?? 0,
        isReadOnly: pane?.isReadOnly ?? false,
        title: pane?.title ?? `Pane ${paneId}`,
        dimensions: pane?.dimensions ?? null,
      };
    },
    shallowEqual
  );
  const {
    connected,
    bellActive,
    cursorStyle,
    cursorColor,
    cursorText,
    cursorBlink,
    focusedPaneId,
    dimensionVersion,
    connection,
    theme,
  } = useStoreSelector(
    (store) => ({
        connected: store.connected,
        bellActive: store.bellActive,
        cursorStyle: store.cursorStyle,
        cursorColor: store.cursorColor,
        cursorText: store.cursorText,
        cursorBlink: store.cursorBlink,
        focusedPaneId: store.focusedPaneId,
        dimensionVersion: store.dimensionVersion,
        connection: store.connection,
        theme: store.theme,
      }),
    shallowEqual
  );

  if (!paneExists) {
    return (
      <div class="not-found">
        <div class="not-found-icon">⚠</div>
        <div class="not-found-title">Pane Not Found</div>
        <div class="not-found-detail">Pane {paneId} does not exist</div>
      </div>
    );
  }

  // This pane has bell if it's focused and bell is active
  const hasBell = bellActive && focusedPaneId === paneId && !isReadOnly;

  // Calculate and report dimensions
  useEffect(() => {
    const container = terminalRef.current;
    if (!container || !connection || isReadOnly) return;

    // Track the current paneId to prevent stale callbacks from affecting wrong panes
    const currentPaneId = paneId;
    let isActive = true;

    const calculate = () => {
      // Skip if this effect has been cleaned up (component unmounted or deps changed)
      if (!isActive) return;

      const size = connection.calculatePaneSize(container);
      if (size.cols > 0 && size.rows > 0) {
        // Update store and notify server with the captured paneId
        setPaneDimensions(currentPaneId, size.cols, size.rows);
        connection.setPaneSize(
          currentPaneId,
          size.cols,
          size.rows,
          size.cellWidth,
          size.cellHeight
        );
      }
    };

    // ResizeObserver is the primary mechanism - fires when container gets sized
    const observer = new ResizeObserver(() => {
      requestAnimationFrame(calculate);
    });
    observer.observe(container);

    // Fallback: delayed calculation for cases where ResizeObserver doesn't fire
    // (e.g., container already at final size when observed)
    const fallbackTimer = window.setTimeout(() => {
      requestAnimationFrame(calculate);
    }, 50);

    return () => {
      isActive = false;
      window.clearTimeout(fallbackTimer);
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

  // Handle pane close button click
  const handleCloseClick = useCallback((e: MouseEvent) => {
    e.stopPropagation(); // Don't trigger pane focus
    if (connection?.isConnected && connection.isMaster) {
      connection.closePane(paneId);
    }
  }, [connection, paneId]);

  const handleResyncClick = useCallback((e: MouseEvent) => {
    e.stopPropagation(); // Don't trigger pane focus
    if (connection?.isConnected) {
      connection.requestResync(paneId, "manual");
    }
  }, [connection, paneId]);

  // Handle right-click on titlebar for pane context menu
  const handleTitlebarContextMenu = useCallback((e: MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (windowId !== undefined && connection?.isMaster) {
      openPaneContextMenu(windowId, paneId, e.clientX, e.clientY);
    }
  }, [windowId, paneId, connection]);

  const displayDims = dimensions && dimensions.cols > 0 ? dimensions : { cols: 80, rows: 24 };
  const isFocused = focusedPaneId === paneId;

  return (
    <div
      class={`terminal-pane${hasBell ? " bell-active" : ""}${isReadOnly ? " terminal-pane--readonly" : ""}${isFocused ? " terminal-pane--focused" : ""}`}
      onClick={handlePaneClick}
    >
      <div class="terminal-titlebar" onContextMenu={handleTitlebarContextMenu}>
        <span class="pane-id-bubble" title={`Pane ${paneId}`}>{paneId}</span>
        <span
          class="terminal-title"
          onClick={hasBell ? handleKeyInput : undefined}
          style={{ cursor: hasBell ? "pointer" : undefined }}
        >
          {hasBell && getBellFeatures().title ? "\u{1F514} " : ""}
          {title}
        </span>
        <span
          class="terminal-sync-stats"
          title={`Generation: ${syncGen}, Deltas: ${syncDeltas}, Resyncs: ${syncResyncs}`}
        >
          {"\u0394"}{syncDeltas} {"\u27F3"}{syncResyncs}
        </span>
        <span
          class="terminal-size"
          title={`Server: ${snapshot?.cols}\u00D7${snapshot?.rows}, Visible: ${displayDims.cols}\u00D7${displayDims.rows}`}
        >
          {snapshot ? `${displayDims.cols}\u00D7${displayDims.rows}` : "\u2014"}
        </span>
        <button
          class="pane-resync"
          onClick={handleResyncClick}
          disabled={!connection?.isConnected}
          title="Request a full snapshot resync for this pane"
        >
          request full snapshot
        </button>
        {!isReadOnly && connection?.isMaster && (
          <button
            class="pane-close"
            onClick={handleCloseClick}
            title="Close pane"
          >
            ×
          </button>
        )}
      </div>
      <div class="terminal-container" ref={terminalRef}>
        <ProgressBar paneId={paneId} />
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
            theme={theme}
            deltaChangedRowIds={deltaChangedRowIds}
            deltaGen={deltaGen}
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
