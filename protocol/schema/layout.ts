// Layout Schema
// Shared between server (Zig) and client (TypeScript)
//
// Layouts define how panes are arranged in a window.
// Split direction is implicit from nesting level:
//   - Level 0 (root): horizontal arrangement (side by side)
//   - Level 1: vertical arrangement (stacked)
//   - Level 2: horizontal again
//   - etc.

// ============================================================================
// Layout Node Types
// ============================================================================

/** Container node - holds child nodes */
export interface LayoutContainer {
  type: "container";
  width: number;   // Percentage (0-100)
  height: number;  // Percentage (0-100)
  children: LayoutNode[];
}

/** Pane node - terminal placeholder */
export interface LayoutPane {
  type: "pane";
  width: number;   // Percentage (0-100)
  height: number;  // Percentage (0-100)
  paneId?: number; // Assigned when window is created from template
}

/** A layout node is either a container or a pane */
export type LayoutNode = LayoutContainer | LayoutPane;

// ============================================================================
// Layout Template (stored in database)
// ============================================================================

/** A named layout template that can be used to create windows */
export interface LayoutTemplate {
  id: string;          // Unique identifier (e.g., "single", "2-col", "2x2")
  name: string;        // Display name (e.g., "Single Pane", "Two Columns")
  nodes: LayoutNode[]; // Top-level nodes (horizontal arrangement)
}

// ============================================================================
// Window Layout (assigned to a window)
// ============================================================================

/** A window's actual layout with panes assigned */
export interface WindowLayout {
  templateId: string;   // Which template it was created from
  nodes: LayoutNode[];  // Deep copy with paneIds assigned
}

// ============================================================================
// Type Guards
// ============================================================================

export function isContainer(node: LayoutNode): node is LayoutContainer {
  return node.type === "container";
}

export function isPane(node: LayoutNode): node is LayoutPane {
  return node.type === "pane";
}

// ============================================================================
// Helper Functions
// ============================================================================

/** Create a pane node */
export function pane(width: number, height: number, paneId?: number): LayoutPane {
  return { type: "pane", width, height, paneId };
}

/** Create a container node */
export function container(width: number, height: number, children: LayoutNode[]): LayoutContainer {
  return { type: "container", width, height, children };
}

/** Deep clone a layout node (for creating window layouts from templates) */
export function cloneNode(node: LayoutNode): LayoutNode {
  if (isPane(node)) {
    return { ...node, paneId: undefined };
  }
  return {
    ...node,
    children: node.children.map(cloneNode),
  };
}

/** Deep clone an array of layout nodes */
export function cloneNodes(nodes: LayoutNode[]): LayoutNode[] {
  return nodes.map(cloneNode);
}

/** Count total panes in a layout */
export function countPanes(nodes: LayoutNode[]): number {
  let count = 0;
  for (const node of nodes) {
    if (isPane(node)) {
      count++;
    } else {
      count += countPanes(node.children);
    }
  }
  return count;
}

/** Get all pane nodes from a layout (flattened) */
export function getAllPanes(nodes: LayoutNode[]): LayoutPane[] {
  const panes: LayoutPane[] = [];
  for (const node of nodes) {
    if (isPane(node)) {
      panes.push(node);
    } else {
      panes.push(...getAllPanes(node.children));
    }
  }
  return panes;
}

/** Assign pane IDs to a layout (mutates in place) */
export function assignPaneIds(nodes: LayoutNode[], paneIds: number[]): void {
  let idx = 0;
  const assign = (nodeList: LayoutNode[]) => {
    for (const node of nodeList) {
      if (isPane(node)) {
        if (idx < paneIds.length) {
          node.paneId = paneIds[idx++];
        }
      } else {
        assign(node.children);
      }
    }
  };
  assign(nodes);
}

// ============================================================================
// Default Layout Templates
// ============================================================================

export const DEFAULT_LAYOUTS: LayoutTemplate[] = [
  {
    id: "single",
    name: "Single Pane",
    nodes: [pane(100, 100)],
  },
  {
    id: "2-col",
    name: "Two Columns",
    nodes: [pane(50, 100), pane(50, 100)],
  },
  {
    id: "2-row",
    name: "Two Rows",
    nodes: [
      container(100, 100, [pane(100, 50), pane(100, 50)]),
    ],
  },
  {
    id: "2x2",
    name: "2×2 Grid",
    nodes: [
      container(50, 100, [pane(100, 50), pane(100, 50)]),
      container(50, 100, [pane(100, 50), pane(100, 50)]),
    ],
  },
  {
    id: "main-side",
    name: "Main + Sidebar",
    nodes: [pane(70, 100), pane(30, 100)],
  },
  {
    id: "main-2side",
    name: "Main + 2 Sidebars",
    nodes: [
      pane(50, 100),
      container(50, 100, [pane(100, 50), pane(100, 50)]),
    ],
  },
  {
    id: "3-col",
    name: "Three Columns",
    nodes: [pane(33.33, 100), pane(33.34, 100), pane(33.33, 100)],
  },
  {
    id: "3-row",
    name: "Three Rows",
    nodes: [
      container(100, 100, [pane(100, 33.33), pane(100, 33.34), pane(100, 33.33)]),
    ],
  },
];

/** Get a layout template by ID */
export function getLayoutTemplate(id: string): LayoutTemplate | undefined {
  return DEFAULT_LAYOUTS.find((t) => t.id === id);
}

/** Create a window layout from a template */
export function createWindowLayout(templateId: string, paneIds: number[]): WindowLayout | null {
  const template = getLayoutTemplate(templateId);
  if (!template) return null;

  const nodes = cloneNodes(template.nodes);
  assignPaneIds(nodes, paneIds);

  return { templateId, nodes };
}
