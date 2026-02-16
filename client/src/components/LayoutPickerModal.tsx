// Layout picker modal - shows available layout templates with previews
// Allows user to pick a layout when creating a new window

import { h } from "preact";
import { useStoreSelector, shallowEqual } from "../hooks/useStoreSubscription";
import { useModalBehavior } from "../hooks/useModalBehavior";
import {
  setLayoutPickerOpen,
  createWindowWithTemplate,
} from "../store";
import type { LayoutTemplate } from "../terminal/connection";
import type { LayoutNode } from "../../../protocol/schema/layout";

/** Render a mini preview of a layout node */
function renderPreviewNode(node: LayoutNode, level: number, key: number): h.JSX.Element {
  const isHorizontal = level % 2 === 0;

  // Use flex for sizing - parent direction determines which dimension matters
  const size = isHorizontal ? node.width : node.height;
  const style = { flex: `${size} 0 0%` };

  if (node.type === "pane") {
    return (
      <div
        key={key}
        class="layout-preview-pane"
        style={style}
      />
    );
  }

  if (node.type === "container") {
    const childLevel = level + 1;
    const childIsHorizontal = childLevel % 2 === 0;
    const containerClass = childIsHorizontal
      ? "layout-preview-container layout-preview-horizontal"
      : "layout-preview-container layout-preview-vertical";

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
    <div class="layout-preview-root">
      {template.nodes.map((node, i) => renderPreviewNode(node, 0, i))}
    </div>
  );
}

export function LayoutPickerModal() {
  const { layoutPickerOpen, layoutTemplates } = useStoreSelector(
    (store) => ({
      layoutPickerOpen: store.layoutPickerOpen,
      layoutTemplates: store.layoutTemplates,
    }),
    shallowEqual
  );

  // Modal behavior (escape key, scroll prevention)
  useModalBehavior({
    isOpen: layoutPickerOpen,
    onClose: () => setLayoutPickerOpen(false),
  });

  if (!layoutPickerOpen) {
    return null;
  }

  const handleSelect = (templateId: string) => {
    createWindowWithTemplate(templateId);
  };

  return (
    <div
      class="layout-picker-modal glassContainer"
      onClick={(e) => e.stopPropagation()}
    >
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
        <p class="layout-picker-hint">Choose a layout:</p>
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
  );
}
