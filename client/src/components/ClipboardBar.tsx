// Clipboard bar component - shows internal 'c' and 'p' clipboards
// Allows syncing between internal clipboards and navigator.clipboard

import { h } from "preact";
import { useState, useEffect } from "preact/hooks";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import {
  getStore,
  copyInternalToSystem,
  copySystemToInternal,
  type ClipboardEntry,
} from "../store";

/** Format timestamp as relative time (e.g., "2s ago", "5m ago") */
function formatTimestamp(timestamp: number): string {
  const now = Date.now();
  const diff = now - timestamp;

  if (diff < 1000) return "now";
  if (diff < 60000) return `${Math.floor(diff / 1000)}s`;
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m`;
  if (diff < 86400000) return `${Math.floor(diff / 3600000)}h`;
  return `${Math.floor(diff / 86400000)}d`;
}

interface ClipboardPanelProps {
  kind: "c" | "p";
  label: string;
  entry: ClipboardEntry | null;
  isRecent: boolean;
}

function ClipboardPanel({ kind, label, entry, isRecent }: ClipboardPanelProps) {
  const handleCopyToSystem = () => {
    void copyInternalToSystem(kind);
  };

  const handleCopyFromSystem = () => {
    void copySystemToInternal(kind);
  };

  return (
    <div class={`clipboard-panel ${isRecent ? "clipboard-panel--recent" : ""}`}>
      <span class="clipboard-panel-label">{label}:</span>
      <div class="clipboard-panel-content">
        {entry ? entry.text : <span class="clipboard-panel-empty">(empty)</span>}
      </div>
      {entry && (
        <span class="clipboard-panel-time" title={new Date(entry.timestamp).toLocaleString()}>
          {formatTimestamp(entry.timestamp)}
        </span>
      )}
      <div class="clipboard-panel-buttons">
        <button
          class="clipboard-btn"
          onClick={handleCopyToSystem}
          disabled={!entry}
          title={`Copy '${kind}' to system clipboard`}
        >
          {"\u2191"}
        </button>
        <button
          class="clipboard-btn"
          onClick={handleCopyFromSystem}
          title={`Copy system clipboard to '${kind}'`}
        >
          {"\u2193"}
        </button>
      </div>
    </div>
  );
}

export function ClipboardBar() {
  useStoreSubscription();
  const store = getStore();
  const { clipboardC, clipboardP } = store;

  // Periodic re-render to update relative timestamps
  const [, setTick] = useState(0);
  useEffect(() => {
    const interval = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(interval);
  }, []);

  // Determine which is most recent
  const cIsRecent =
    clipboardC &&
    (!clipboardP || clipboardC.timestamp >= clipboardP.timestamp);
  const pIsRecent =
    clipboardP &&
    (!clipboardC || clipboardP.timestamp > clipboardC.timestamp);

  return (
    <div class="clipboard-bar">
      <ClipboardPanel
        kind="c"
        label="CLIPBOARD"
        entry={clipboardC}
        isRecent={!!cIsRecent}
      />
      <ClipboardPanel
        kind="p"
        label="PRIMARY"
        entry={clipboardP}
        isRecent={!!pIsRecent}
      />
    </div>
  );
}
