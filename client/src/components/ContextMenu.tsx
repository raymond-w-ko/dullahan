// Context menu component - handles window, pane, and hidden panes picker menus
// Window menu: right-click on window tabs, shows close/layout options
// Pane menu: right-click on pane titlebar, shows swap/hide options
// Hidden picker: click on +N indicator, shows hidden panes to bring into view

import { h } from "preact";
import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import {
  getStore,
  getPane,
  closeContextMenu,
  closeWindow,
  setWindowLayout,
  swapPanes,
} from "../store";
import type { WindowContextMenuState, PaneContextMenuState, HiddenPanesPickerState, WindowState } from "../store";
import type { LayoutTemplate } from "../terminal/connection";
import type { LayoutNode } from "../../../protocol/schema/layout";
import { countPanes } from "../../../protocol/schema/layout";

/** Get visible and hidden pane IDs for a window */
function getVisibleAndHiddenPanes(win: WindowState): { visible: number[]; hidden: number[] } {
  const totalPanes = win.paneIds.length;
  const visibleCount = win.layout ? countPanes(win.layout.nodes) : totalPanes;
  const visible = win.paneIds.slice(0, visibleCount);
  const hidden = win.paneIds.slice(visibleCount);
  return { visible, hidden };
}

/** Render a mini preview of a layout node */
function renderPreviewNode(node: LayoutNode, level: number, key: number): h.JSX.Element {
  const isHorizontal = level % 2 === 0;
  const size = isHorizontal ? node.width : node.height;
  const style = { flex: `${size} 0 0%` };

  if (node.type === "pane") {
    return <div key={key} class="context-menu-preview-pane" style={style} />;
  }

  if (node.type === "container") {
    const childLevel = level + 1;
    const childIsHorizontal = childLevel % 2 === 0;
    const containerClass = childIsHorizontal
      ? "context-menu-preview-container context-menu-preview-horizontal"
      : "context-menu-preview-container context-menu-preview-vertical";

    return (
      <div key={key} class={containerClass} style={style}>
        {node.children.map((child, i) => renderPreviewNode(child, childLevel, i))}
      </div>
    );
  }

  return <div key={key} />;
}

/** Render a mini preview of a layout template */
function LayoutPreview({ template }: { template: LayoutTemplate }) {
  return (
    <div class="context-menu-preview-root">
      {template.nodes.map((node, i) => renderPreviewNode(node, 0, i))}
    </div>
  );
}

interface LayoutSubmenuProps {
  templates: LayoutTemplate[];
  windowId: number;
  parentRect: DOMRect | null;
}

function LayoutSubmenu({ templates, windowId, parentRect }: LayoutSubmenuProps) {
  const submenuRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ left: boolean; above: boolean }>({ left: false, above: false });

  // Position submenu based on available space
  useEffect(() => {
    if (!submenuRef.current || !parentRect) return;

    const submenu = submenuRef.current;
    const rect = submenu.getBoundingClientRect();
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;

    // Check if submenu would overflow right edge
    const wouldOverflowRight = parentRect.right + rect.width > viewportWidth;
    // Check if submenu would overflow bottom edge
    const wouldOverflowBottom = parentRect.top + rect.height > viewportHeight;

    setPosition({ left: wouldOverflowRight, above: wouldOverflowBottom });
  }, [parentRect]);

  const handleSelect = (templateId: string) => {
    setWindowLayout(windowId, templateId);
  };

  const classes = [
    "context-submenu",
    "glassContainer",
    position.left ? "context-submenu--left" : "",
    position.above ? "context-submenu--above" : "",
  ].filter(Boolean).join(" ");

  return (
    <div ref={submenuRef} class={classes}>
      {templates.map((template) => (
        <button
          key={template.id}
          class="context-menu-item context-menu-item--layout"
          onClick={() => handleSelect(template.id)}
        >
          <LayoutPreview template={template} />
          <span class="context-menu-item-label">{template.name}</span>
        </button>
      ))}
    </div>
  );
}

/** Window context menu content - shows close/layout options */
function WindowMenuContent({ menu }: { menu: WindowContextMenuState }) {
  const store = getStore();
  const { layoutTemplates, isMaster, windows } = store;

  const layoutItemRef = useRef<HTMLDivElement>(null);
  const [showLayoutSubmenu, setShowLayoutSubmenu] = useState(false);
  const [layoutItemRect, setLayoutItemRect] = useState<DOMRect | null>(null);

  const handleLayoutMouseEnter = useCallback(() => {
    if (layoutItemRef.current) {
      setLayoutItemRect(layoutItemRef.current.getBoundingClientRect());
    }
    setShowLayoutSubmenu(true);
  }, []);

  const handleLayoutMouseLeave = useCallback((e: MouseEvent) => {
    // Don't close if moving to submenu
    const relatedTarget = e.relatedTarget as Node | null;
    const parent = layoutItemRef.current?.parentElement;
    if (relatedTarget && parent?.contains(relatedTarget)) {
      return;
    }
    setShowLayoutSubmenu(false);
  }, []);

  const canChangeLayout = isMaster && layoutTemplates.length > 0;
  const canCloseWindow = isMaster && windows.size > 1;

  const handleCloseWindow = useCallback(() => {
    if (!canCloseWindow) return;
    closeWindow(menu.windowId);
    closeContextMenu();
  }, [canCloseWindow, menu.windowId]);

  return (
    <>
      {canCloseWindow && (
        <button class="context-menu-item" onClick={handleCloseWindow}>
          <span class="context-menu-item-label">Close window</span>
        </button>
      )}
      {!canCloseWindow && (
        <div class="context-menu-item context-menu-item--disabled">
          <span class="context-menu-item-label">
            {isMaster ? "Can't close last window" : "Close window (master only)"}
          </span>
        </div>
      )}
      <div class="context-menu-divider" />
      {canChangeLayout && (
        <div
          ref={layoutItemRef}
          class="context-menu-item context-menu-item--submenu"
          onMouseEnter={handleLayoutMouseEnter}
          onMouseLeave={handleLayoutMouseLeave}
        >
          <span class="context-menu-item-label">Layout</span>
          <span class="context-menu-arrow">▶</span>
          {showLayoutSubmenu && (
            <LayoutSubmenu
              templates={layoutTemplates}
              windowId={menu.windowId}
              parentRect={layoutItemRect}
            />
          )}
        </div>
      )}
      {!canChangeLayout && (
        <div class="context-menu-item context-menu-item--disabled">
          <span class="context-menu-item-label">
            {isMaster ? "No layouts available" : "Layout (master only)"}
          </span>
        </div>
      )}
    </>
  );
}

/** Get pane display name */
function getPaneName(paneId: number): string {
  const pane = getPane(paneId);
  if (pane && pane.title) {
    // Truncate long titles
    const title = pane.title.length > 20 ? pane.title.slice(0, 20) + "..." : pane.title;
    return `${paneId}: ${title}`;
  }
  return `Pane ${paneId}`;
}

/** Pane context menu content - shows swap and hide options */
function PaneMenuContent({ menu }: { menu: PaneContextMenuState }) {
  const store = getStore();
  const { windows, isMaster } = store;
  const win = windows.get(menu.windowId);

  if (!win || !isMaster) {
    return (
      <div class="context-menu-item context-menu-item--disabled">
        <span class="context-menu-item-label">
          {isMaster ? "Window not found" : "Master only"}
        </span>
      </div>
    );
  }

  const { visible, hidden } = getVisibleAndHiddenPanes(win);
  const isVisible = visible.includes(menu.paneId);

  // Other visible panes (excluding current)
  const otherVisible = visible.filter(id => id !== menu.paneId);

  const handleSwap = (targetPaneId: number) => {
    swapPanes(menu.windowId, menu.paneId, targetPaneId);
  };

  const handleHide = () => {
    // Swap with the first hidden pane to move this pane to hidden
    const firstHidden = hidden[0];
    if (firstHidden !== undefined) {
      swapPanes(menu.windowId, menu.paneId, firstHidden);
    }
  };

  const hasSwapTargets = otherVisible.length > 0 || hidden.length > 0;

  return (
    <>
      {isVisible && hasSwapTargets && (
        <>
          <div class="context-menu-header">Swap with...</div>
          {otherVisible.length > 0 && (
            <>
              {otherVisible.map((paneId) => (
                <button
                  key={paneId}
                  class="context-menu-item"
                  onClick={() => handleSwap(paneId)}
                >
                  <span class="context-menu-item-label">{getPaneName(paneId)}</span>
                </button>
              ))}
            </>
          )}
          {hidden.length > 0 && otherVisible.length > 0 && (
            <div class="context-menu-divider" />
          )}
          {hidden.length > 0 && (
            <>
              <div class="context-menu-header">Hidden</div>
              {hidden.map((paneId) => (
                <button
                  key={paneId}
                  class="context-menu-item"
                  onClick={() => handleSwap(paneId)}
                >
                  <span class="context-menu-item-label">{getPaneName(paneId)}</span>
                </button>
              ))}
            </>
          )}
        </>
      )}
      {isVisible && hidden.length > 0 && (
        <>
          <div class="context-menu-divider" />
          <button
            class="context-menu-item"
            onClick={handleHide}
          >
            <span class="context-menu-item-label">Hide this pane</span>
          </button>
        </>
      )}
      {isVisible && !hasSwapTargets && (
        <div class="context-menu-item context-menu-item--disabled">
          <span class="context-menu-item-label">Only one pane</span>
        </div>
      )}
      {!isVisible && (
        <div class="context-menu-item context-menu-item--disabled">
          <span class="context-menu-item-label">Pane is hidden</span>
        </div>
      )}
    </>
  );
}

/** Hidden panes picker content - shows list of hidden panes */
function HiddenPickerContent({ menu }: { menu: HiddenPanesPickerState }) {
  const store = getStore();
  const { windows, isMaster, focusedPaneId } = store;
  const win = windows.get(menu.windowId);

  if (!win || !isMaster) {
    return (
      <div class="context-menu-item context-menu-item--disabled">
        <span class="context-menu-item-label">
          {isMaster ? "Window not found" : "Master only"}
        </span>
      </div>
    );
  }

  const { visible, hidden } = getVisibleAndHiddenPanes(win);

  // Determine which visible pane to swap with (prefer focused, else first visible)
  const swapTarget = visible.includes(focusedPaneId) ? focusedPaneId : visible[0];

  const handleSelect = (hiddenPaneId: number) => {
    if (swapTarget !== undefined) {
      swapPanes(menu.windowId, swapTarget, hiddenPaneId);
    }
  };

  if (hidden.length === 0) {
    return (
      <div class="context-menu-item context-menu-item--disabled">
        <span class="context-menu-item-label">No hidden panes</span>
      </div>
    );
  }

  return (
    <>
      <div class="context-menu-header">Bring into view...</div>
      {hidden.map((hiddenPaneId) => (
        <button
          key={hiddenPaneId}
          class="context-menu-item"
          onClick={() => handleSelect(hiddenPaneId)}
        >
          <span class="context-menu-item-label">{getPaneName(hiddenPaneId)}</span>
        </button>
      ))}
    </>
  );
}

export function ContextMenu() {
  useStoreSubscription();

  const store = getStore();
  const { contextMenu } = store;

  const menuRef = useRef<HTMLDivElement>(null);
  const [menuPosition, setMenuPosition] = useState({ x: 0, y: 0 });

  // Close on escape
  useEffect(() => {
    if (!contextMenu) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        closeContextMenu();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [contextMenu]);

  // Close on outside click
  useEffect(() => {
    if (!contextMenu) return;

    const handleClick = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        closeContextMenu();
      }
    };

    // Use mousedown for immediate response
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [contextMenu]);

  // Adjust position to keep menu in viewport
  useEffect(() => {
    if (!contextMenu || !menuRef.current) return;

    const menu = menuRef.current;
    const rect = menu.getBoundingClientRect();
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;

    let x = contextMenu.x;
    let y = contextMenu.y;

    // Adjust if menu would overflow right edge
    if (x + rect.width > viewportWidth) {
      x = viewportWidth - rect.width - 8;
    }

    // Adjust if menu would overflow bottom edge - open upward
    if (y + rect.height > viewportHeight) {
      y = contextMenu.y - rect.height;
    }

    // Ensure menu doesn't go off left/top edge
    x = Math.max(8, x);
    y = Math.max(8, y);

    setMenuPosition({ x, y });
  }, [contextMenu]);

  if (!contextMenu) return null;

  // Render appropriate content based on menu type
  let content: h.JSX.Element;
  switch (contextMenu.kind) {
    case "window":
      content = <WindowMenuContent menu={contextMenu} />;
      break;
    case "pane":
      content = <PaneMenuContent menu={contextMenu} />;
      break;
    case "hidden_picker":
      content = <HiddenPickerContent menu={contextMenu} />;
      break;
  }

  return (
    <div
      ref={menuRef}
      class="context-menu glassContainer"
      style={{ left: `${menuPosition.x}px`, top: `${menuPosition.y}px` }}
      onClick={(e) => e.stopPropagation()}
    >
      {content}
    </div>
  );
}
