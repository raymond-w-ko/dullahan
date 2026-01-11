// Window switcher component - tab bar for switching between windows
// Master clients can also create new windows via layout picker

import { h } from "preact";
import { getStore, switchWindow, setLayoutPickerOpen } from "../store";

export function WindowSwitcher() {
  const store = getStore();
  const { windows, activeWindowId, isMaster } = store;

  // Convert windows map to sorted array
  const windowList = Array.from(windows.values()).sort((a, b) => a.id - b.id);

  // Show switcher if multiple windows exist (anyone can switch)
  // or if master (who can create new windows via + button)
  const hasMultipleWindows = windowList.length > 1;
  if (!hasMultipleWindows && !isMaster) {
    return null;
  }

  return (
    <div class="window-switcher">
      {windowList.map((win) => (
        <button
          key={win.id}
          class={`window-tab ${win.id === activeWindowId ? "window-tab--active" : ""}`}
          onClick={() => switchWindow(win.id)}
          title={`Window ${win.id}`}
        >
          {win.id}
        </button>
      ))}
      {isMaster && (
        <button
          class="window-tab window-tab--add"
          onClick={() => setLayoutPickerOpen(true)}
          title="Create new window"
        >
          +
        </button>
      )}
    </div>
  );
}
