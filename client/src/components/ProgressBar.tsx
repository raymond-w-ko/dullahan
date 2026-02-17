// Progress bar component - thin vertical strip for taskbar progress (OSC 9;4)
// Ghostty-style: minimal, positioned at top edge of each pane

import { h } from "preact";
import { useStoreSelector } from "../hooks/useStoreSubscription";

export interface ProgressBarProps {
  paneId: number;
}

export function ProgressBar({ paneId }: ProgressBarProps) {
  const progress = useStoreSelector((store) => {
    const current = store.progress;
    if (!current || current.state === 0 || current.paneId !== paneId) {
      return null;
    }
    return current;
  });

  if (!progress) {
    return null;
  }

  // State classes: 1=normal, 2=error, 3=indeterminate, 4=warning
  const stateClass = {
    1: "progress-bar--normal",
    2: "progress-bar--error",
    3: "progress-bar--indeterminate",
    4: "progress-bar--warning",
  }[progress.state] ?? "progress-bar--normal";

  const isIndeterminate = progress.state === 3;

  return (
    <div class={`progress-bar ${stateClass}`}>
      <div
        class="progress-bar-fill"
        style={isIndeterminate ? undefined : { width: `${progress.value}%` }}
      />
    </div>
  );
}
