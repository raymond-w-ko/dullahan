/**
 * Tests for layout schema.
 */

import { describe, test, expect } from "bun:test";
import {
  LayoutNode,
  LayoutPane,
  LayoutContainer,
  LayoutTemplate,
  isContainer,
  isPane,
  pane,
  container,
  cloneNode,
  cloneNodes,
  countPanes,
  getAllPanes,
  assignPaneIds,
  DEFAULT_LAYOUTS,
  getLayoutTemplate,
  createWindowLayout,
} from "./layout";

describe("type guards", () => {
  test("isPane returns true for pane nodes", () => {
    const node: LayoutNode = { type: "pane", width: 100, height: 100 };
    expect(isPane(node)).toBe(true);
    expect(isContainer(node)).toBe(false);
  });

  test("isContainer returns true for container nodes", () => {
    const node: LayoutNode = {
      type: "container",
      width: 100,
      height: 100,
      children: [],
    };
    expect(isContainer(node)).toBe(true);
    expect(isPane(node)).toBe(false);
  });
});

describe("helper constructors", () => {
  test("pane() creates a pane node", () => {
    const p = pane(50, 100);
    expect(p.type).toBe("pane");
    expect(p.width).toBe(50);
    expect(p.height).toBe(100);
    expect(p.paneId).toBeUndefined();
  });

  test("pane() with paneId", () => {
    const p = pane(50, 100, 42);
    expect(p.paneId).toBe(42);
  });

  test("container() creates a container node", () => {
    const c = container(100, 50, [pane(50, 100), pane(50, 100)]);
    expect(c.type).toBe("container");
    expect(c.width).toBe(100);
    expect(c.height).toBe(50);
    expect(c.children.length).toBe(2);
  });
});

describe("cloneNode", () => {
  test("clones a pane and clears paneId", () => {
    const original = pane(50, 100, 42);
    const cloned = cloneNode(original) as LayoutPane;

    expect(cloned.type).toBe("pane");
    expect(cloned.width).toBe(50);
    expect(cloned.height).toBe(100);
    expect(cloned.paneId).toBeUndefined();
    // Original unchanged
    expect(original.paneId).toBe(42);
  });

  test("clones a container deeply", () => {
    const original = container(100, 100, [
      pane(50, 100, 1),
      container(50, 100, [pane(100, 50, 2), pane(100, 50, 3)]),
    ]);

    const cloned = cloneNode(original) as LayoutContainer;

    expect(cloned.type).toBe("container");
    expect(cloned.children.length).toBe(2);

    // First child is a pane with cleared paneId
    const firstChild = cloned.children[0] as LayoutPane;
    expect(firstChild.type).toBe("pane");
    expect(firstChild.paneId).toBeUndefined();

    // Second child is a container
    const secondChild = cloned.children[1] as LayoutContainer;
    expect(secondChild.type).toBe("container");
    expect(secondChild.children.length).toBe(2);

    // Nested panes have cleared paneIds
    const nestedPane = secondChild.children[0] as LayoutPane;
    expect(nestedPane.paneId).toBeUndefined();

    // Original paneIds unchanged
    const originalPane = (original.children[0] as LayoutPane);
    expect(originalPane.paneId).toBe(1);
  });
});

describe("countPanes", () => {
  test("counts single pane", () => {
    expect(countPanes([pane(100, 100)])).toBe(1);
  });

  test("counts multiple panes", () => {
    expect(countPanes([pane(50, 100), pane(50, 100)])).toBe(2);
  });

  test("counts panes in nested containers", () => {
    const layout = [
      container(50, 100, [pane(100, 50), pane(100, 50)]),
      pane(50, 100),
    ];
    expect(countPanes(layout)).toBe(3);
  });

  test("counts panes in deeply nested structure", () => {
    const layout = [
      container(50, 100, [
        container(100, 50, [pane(50, 100), pane(50, 100)]),
        pane(100, 50),
      ]),
      pane(50, 100),
    ];
    expect(countPanes(layout)).toBe(4);
  });
});

describe("getAllPanes", () => {
  test("returns all panes flattened", () => {
    const p1 = pane(50, 100, 1);
    const p2 = pane(50, 100, 2);
    const p3 = pane(100, 50, 3);

    const layout = [container(50, 100, [p1, p2]), p3];
    const panes = getAllPanes(layout);

    expect(panes.length).toBe(3);
    expect(panes[0].paneId).toBe(1);
    expect(panes[1].paneId).toBe(2);
    expect(panes[2].paneId).toBe(3);
  });
});

describe("assignPaneIds", () => {
  test("assigns paneIds in order", () => {
    const layout = [pane(50, 100), pane(50, 100)];
    assignPaneIds(layout, [10, 20]);

    expect((layout[0] as LayoutPane).paneId).toBe(10);
    expect((layout[1] as LayoutPane).paneId).toBe(20);
  });

  test("assigns to nested panes", () => {
    const layout = [
      container(50, 100, [pane(100, 50), pane(100, 50)]),
      pane(50, 100),
    ];
    assignPaneIds(layout, [1, 2, 3]);

    const c = layout[0] as LayoutContainer;
    expect((c.children[0] as LayoutPane).paneId).toBe(1);
    expect((c.children[1] as LayoutPane).paneId).toBe(2);
    expect((layout[1] as LayoutPane).paneId).toBe(3);
  });

  test("handles fewer paneIds than panes", () => {
    const layout = [pane(50, 100), pane(50, 100)];
    assignPaneIds(layout, [10]);

    expect((layout[0] as LayoutPane).paneId).toBe(10);
    expect((layout[1] as LayoutPane).paneId).toBeUndefined();
  });
});

describe("DEFAULT_LAYOUTS", () => {
  test("has expected layouts", () => {
    expect(DEFAULT_LAYOUTS.length).toBeGreaterThanOrEqual(6);

    const ids = DEFAULT_LAYOUTS.map((l) => l.id);
    expect(ids).toContain("single");
    expect(ids).toContain("2-col");
    expect(ids).toContain("2-row");
    expect(ids).toContain("2x2");
    expect(ids).toContain("main-side");
    expect(ids).toContain("main-2side");
  });

  test("single layout has 1 pane", () => {
    const layout = getLayoutTemplate("single");
    expect(layout).toBeDefined();
    expect(countPanes(layout!.nodes)).toBe(1);
  });

  test("2-col layout has 2 panes", () => {
    const layout = getLayoutTemplate("2-col");
    expect(layout).toBeDefined();
    expect(countPanes(layout!.nodes)).toBe(2);
  });

  test("2x2 layout has 4 panes", () => {
    const layout = getLayoutTemplate("2x2");
    expect(layout).toBeDefined();
    expect(countPanes(layout!.nodes)).toBe(4);
  });

  test("3-col layout has 3 panes", () => {
    const layout = getLayoutTemplate("3-col");
    expect(layout).toBeDefined();
    expect(countPanes(layout!.nodes)).toBe(3);
  });
});

describe("getLayoutTemplate", () => {
  test("returns layout by id", () => {
    const layout = getLayoutTemplate("single");
    expect(layout).toBeDefined();
    expect(layout!.id).toBe("single");
    expect(layout!.name).toBe("Single Pane");
  });

  test("returns undefined for unknown id", () => {
    const layout = getLayoutTemplate("nonexistent");
    expect(layout).toBeUndefined();
  });
});

describe("createWindowLayout", () => {
  test("creates layout from template with paneIds", () => {
    const windowLayout = createWindowLayout("2-col", [10, 20]);

    expect(windowLayout).not.toBeNull();
    expect(windowLayout!.templateId).toBe("2-col");
    expect(windowLayout!.nodes.length).toBe(2);

    const panes = getAllPanes(windowLayout!.nodes);
    expect(panes[0].paneId).toBe(10);
    expect(panes[1].paneId).toBe(20);
  });

  test("returns null for unknown template", () => {
    const windowLayout = createWindowLayout("nonexistent", [1, 2]);
    expect(windowLayout).toBeNull();
  });

  test("does not mutate original template", () => {
    const template = getLayoutTemplate("2-col")!;
    const originalPanes = getAllPanes(template.nodes);

    createWindowLayout("2-col", [100, 200]);

    // Original template unchanged
    const panes = getAllPanes(template.nodes);
    expect(panes[0].paneId).toBeUndefined();
    expect(panes[1].paneId).toBeUndefined();
  });
});
