// Context menu component with layout submenu
// Appears on right-click of window tabs

import { h } from "preact";
import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import {
  getStore,
  closeContextMenu,
  setWindowLayout,
} from "../store";
import type { LayoutTemplate } from "../terminal/connection";
import type { LayoutNode } from "../../../protocol/schema/layout";

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

interface SubmenuProps {
  templates: LayoutTemplate[];
  windowId: number;
  parentRect: DOMRect | null;
}

function LayoutSubmenu({ templates, windowId, parentRect }: SubmenuProps) {
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

export function ContextMenu() {
  useStoreSubscription();

  const store = getStore();
  const { contextMenu, layoutTemplates, isMaster } = store;

  const menuRef = useRef<HTMLDivElement>(null);
  const layoutItemRef = useRef<HTMLDivElement>(null);
  const [showLayoutSubmenu, setShowLayoutSubmenu] = useState(false);
  const [menuPosition, setMenuPosition] = useState({ x: 0, y: 0 });
  const [layoutItemRect, setLayoutItemRect] = useState<DOMRect | null>(null);

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

  // Update layout item rect when hovering
  const handleLayoutMouseEnter = useCallback(() => {
    if (layoutItemRef.current) {
      setLayoutItemRect(layoutItemRef.current.getBoundingClientRect());
    }
    setShowLayoutSubmenu(true);
  }, []);

  const handleLayoutMouseLeave = useCallback((e: MouseEvent) => {
    // Don't close if moving to submenu
    const relatedTarget = e.relatedTarget as Node | null;
    if (relatedTarget && menuRef.current?.contains(relatedTarget)) {
      return;
    }
    setShowLayoutSubmenu(false);
  }, []);

  if (!contextMenu) return null;

  // Only master can change layouts
  const canChangeLayout = isMaster && layoutTemplates.length > 0;

  return (
    <div
      ref={menuRef}
      class="context-menu glassContainer"
      style={{ left: `${menuPosition.x}px`, top: `${menuPosition.y}px` }}
      onClick={(e) => e.stopPropagation()}
    >
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
              windowId={contextMenu.windowId}
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
    </div>
  );
}
