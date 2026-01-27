// Window switcher component - tab bar for switching between windows
// Master clients can also create new windows via layout picker
// Right-click on tabs opens context menu with layout options

import { h } from "preact";
import { getStore, switchWindow, setLayoutPickerOpen, openWindowContextMenu, openHiddenPanesPicker } from "../store";
import type { WindowState } from "../store";
import { countPanes } from "../../../protocol/schema/layout";

/** Calculate number of hidden panes in a window */
function getHiddenPaneCount(win: WindowState): number {
  const totalPanes = win.paneIds.length;
  const visiblePanes = win.layout ? countPanes(win.layout.nodes) : totalPanes;
  return Math.max(0, totalPanes - visiblePanes);
}

/** Format window tab label (display id + 1 to match Alt+N keybinds) */
function getWindowLabel(win: WindowState): string {
  const displayId = win.id + 1;
  const hidden = getHiddenPaneCount(win);
  if (hidden > 0) {
    return `${displayId} (+${hidden})`;
  }
  return String(displayId);
}

/** Format window tab tooltip (display id + 1 to match Alt+N keybinds) */
function getWindowTooltip(win: WindowState): string {
  const displayId = win.id + 1;
  const hidden = getHiddenPaneCount(win);
  if (hidden > 0) {
    return `Window ${displayId} (${hidden} pane${hidden > 1 ? "s" : ""} hidden) - right-click for options`;
  }
  return `Window ${displayId} - right-click for options`;
}

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

  const handleContextMenu = (e: MouseEvent, windowId: number) => {
    e.preventDefault();
    openWindowContextMenu(windowId, e.clientX, e.clientY);
  };

  const handleHiddenClick = (e: MouseEvent, windowId: number) => {
    e.stopPropagation(); // Don't trigger window switch
    openHiddenPanesPicker(windowId, e.clientX, e.clientY);
  };

  return (
    <div class="window-switcher">
      {windowList.map((win) => {
        const hidden = getHiddenPaneCount(win);
        const classes = [
          "window-tab",
          win.id === activeWindowId ? "window-tab--active" : "",
          hidden > 0 ? "window-tab--has-hidden" : "",
        ].filter(Boolean).join(" ");

        return (
          <button
            key={win.id}
            class={classes}
            onClick={() => switchWindow(win.id)}
            onContextMenu={(e) => handleContextMenu(e, win.id)}
            title={getWindowTooltip(win)}
          >
            {win.id + 1}
            {hidden > 0 && (
              <span
                class={`window-tab-hidden${isMaster ? " window-tab-hidden--clickable" : ""}`}
                onClick={isMaster ? (e) => handleHiddenClick(e, win.id) : undefined}
                title={isMaster
                  ? `${hidden} hidden pane${hidden > 1 ? "s" : ""} - click to show`
                  : `${hidden} hidden pane${hidden > 1 ? "s" : ""}`
                }
              >
                +{hidden}
              </span>
            )}
          </button>
        );
      })}
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
