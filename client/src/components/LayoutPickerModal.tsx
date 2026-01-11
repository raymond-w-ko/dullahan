// Layout picker modal - shows available layout templates with previews
// Allows user to pick a layout when creating a new window

import { h } from "preact";
import { useState, useEffect } from "preact/hooks";
import {
  getStore,
  subscribe,
  setLayoutPickerOpen,
  createWindowWithTemplate,
} from "../store";
import type { LayoutTemplate } from "../terminal/connection";
import type { LayoutNode } from "../../../protocol/schema/layout";

/** Render a mini preview of a layout node */
function renderPreviewNode(node: LayoutNode, level: number): h.JSX.Element {
  const isHorizontal = level % 2 === 0;

  if (node.type === "pane") {
    const style = isHorizontal
      ? { width: `${node.width}%`, height: "100%" }
      : { width: "100%", height: `${node.height}%` };

    return (
      <div
        class="layout-preview-pane"
        style={style}
      />
    );
  }

  if (node.type === "container") {
    const style = isHorizontal
      ? { width: `${node.width}%`, height: "100%" }
      : { width: "100%", height: `${node.height}%` };

    const childLevel = level + 1;
    const childIsHorizontal = childLevel % 2 === 0;
    const containerClass = childIsHorizontal
      ? "layout-preview-container layout-preview-horizontal"
      : "layout-preview-container layout-preview-vertical";

    return (
      <div class={containerClass} style={style}>
        {node.children.map((child, i) => (
          <span key={i}>{renderPreviewNode(child, childLevel)}</span>
        ))}
      </div>
    );
  }

  return <span />;
}

/** Render a mini preview of a layout template */
function LayoutPreview({ template }: { template: LayoutTemplate }) {
  const isHorizontal = true; // Root level is always horizontal
  const rootClass = isHorizontal
    ? "layout-preview-root layout-preview-horizontal"
    : "layout-preview-root layout-preview-vertical";

  return (
    <div class={rootClass}>
      {template.nodes.map((node, i) => (
        <span key={i}>{renderPreviewNode(node, 0)}</span>
      ))}
    </div>
  );
}

export function LayoutPickerModal() {
  const [, forceUpdate] = useState(0);

  useEffect(() => {
    return subscribe(() => forceUpdate((n) => n + 1));
  }, []);

  const store = getStore();
  const { layoutPickerOpen, layoutTemplates } = store;

  if (!layoutPickerOpen) {
    return null;
  }

  const handleBackdropClick = (e: MouseEvent) => {
    if ((e.target as HTMLElement).classList.contains("layout-picker-backdrop")) {
      setLayoutPickerOpen(false);
    }
  };

  const handleSelect = (templateId: string) => {
    createWindowWithTemplate(templateId);
  };

  return (
    <div class="layout-picker-backdrop" onClick={handleBackdropClick}>
      <div class="layout-picker-modal glass">
        <div class="layout-picker-header">
          <h2>New Window</h2>
          <button
            class="layout-picker-close"
            onClick={() => setLayoutPickerOpen(false)}
          >
            &times;
          </button>
        </div>
        <div class="layout-picker-content">
          <p class="layout-picker-hint">Choose a layout for the new window:</p>
          <div class="layout-picker-grid">
            {layoutTemplates.map((template) => (
              <button
                key={template.id}
                class="layout-picker-item"
                onClick={() => handleSelect(template.id)}
                title={template.name}
              >
                <LayoutPreview template={template} />
                <span class="layout-picker-name">{template.name}</span>
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
