// Recursive layout renderer component
// Renders layout tree using inline-block CSS

import { h, Fragment } from "preact";
import { TerminalPane } from "./TerminalPane";
import type { LayoutNode } from "../../../protocol/schema/layout";
import { isContainer, isPane } from "../../../protocol/schema/layout";

export interface LayoutRendererProps {
  nodes: LayoutNode[];
  level?: number; // Nesting level (0 = root, horizontal)
}

/**
 * Render a single layout node (container or pane)
 */
function renderNode(node: LayoutNode, level: number, index: number): h.JSX.Element {
  // Even levels = horizontal, odd levels = vertical
  const isHorizontal = level % 2 === 0;

  if (isPane(node)) {
    // Pane node - render terminal
    const style = isHorizontal
      ? { width: `${node.width}%`, height: "100%" }
      : { width: "100%", height: `${node.height}%` };

    return (
      <div
        key={`pane-${node.paneId ?? index}`}
        class="layout-pane"
        style={style}
      >
        {node.paneId !== undefined ? (
          <TerminalPane paneId={node.paneId} />
        ) : (
          <div class="terminal--empty">
            <span class="terminal-placeholder-text">No pane assigned</span>
          </div>
        )}
      </div>
    );
  }

  if (isContainer(node)) {
    // Container node - recurse into children
    const style = isHorizontal
      ? { width: `${node.width}%`, height: "100%" }
      : { width: "100%", height: `${node.height}%` };

    // Children are at next level (alternating direction)
    const childLevel = level + 1;
    const childIsHorizontal = childLevel % 2 === 0;
    const containerClass = childIsHorizontal
      ? "layout-container layout-horizontal"
      : "layout-container layout-vertical";

    return (
      <div
        key={`container-${index}`}
        class={containerClass}
        style={style}
      >
        {node.children.map((child, i) => renderNode(child, childLevel, i))}
      </div>
    );
  }

  // Unknown node type
  return <Fragment key={`unknown-${index}`} />;
}

/**
 * LayoutRenderer - recursively renders a layout tree
 *
 * Layout direction alternates by nesting level:
 * - Level 0 (root): horizontal (children side by side)
 * - Level 1: vertical (children stacked)
 * - Level 2: horizontal again
 * - etc.
 */
export function LayoutRenderer({ nodes, level = 0 }: LayoutRendererProps) {
  // Root level determines initial direction
  const isHorizontal = level % 2 === 0;
  const rootClass = isHorizontal
    ? "layout-root layout-horizontal"
    : "layout-root layout-vertical";

  return (
    <div class={rootClass}>
      {nodes.map((node, i) => renderNode(node, level, i))}
    </div>
  );
}
