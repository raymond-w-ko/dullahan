import { describe, expect, test } from "bun:test";
import type { VNode } from "preact";
import { DEFAULT_STYLE } from "../../../protocol/schema/style";
import type { StyledRun } from "./cellRendering";
import { renderLine, type CursorConfig, type CursorState } from "./cursorRendering";

const hiddenCursor: CursorState = { x: 0, y: 0, visible: false, blink: false };
const cursorConfig: CursorConfig = {
  style: "block",
  color: "",
  textColor: "",
  blink: "false",
};

function run(overrides: Partial<StyledRun> & Pick<StyledRun, "text" | "cellCount">): StyledRun {
  return {
    styleId: 0,
    style: DEFAULT_STYLE,
    ...overrides,
  };
}

function children(vnode: VNode): Array<VNode<Record<string, any>>> {
  return vnode.props.children as Array<VNode<Record<string, any>>>;
}

describe("cursor rendering", () => {
  test("renders fixed one- and two-cell runs with inherited-font classes", () => {
    const vnode = renderLine(
      [
        run({ text: "➛", cellCount: 1, fixedWidth: 1 }),
        run({ text: "中", cellCount: 2, fixedWidth: 2 }),
      ],
      0,
      hiddenCursor,
      cursorConfig,
      false,
      3
    );

    const elements = children(vnode);
    expect(elements[0]!.props.class).toContain("fixed-cell");
    expect(elements[0]!.props.class).not.toContain("fixed-cell-wide");
    expect(elements[1]!.props.class).toContain("fixed-cell fixed-cell-wide");
  });

  test("splits an ordinary run around the cursor by logical cell", () => {
    const vnode = renderLine(
      [run({ text: "ABC", cellCount: 3 })],
      0,
      { x: 1, y: 0, visible: true, blink: false },
      cursorConfig,
      true,
      3
    );

    const elements = children(vnode);
    expect(elements.map((element) => element.props.children)).toEqual(["A", "B", "C"]);
    expect(elements[1]!.props.class).toContain("cursor-block");
  });

  test("applies the cursor to a fixed wide run as one render unit", () => {
    const vnode = renderLine(
      [run({ text: "中", cellCount: 2, fixedWidth: 2 })],
      0,
      { x: 0, y: 0, visible: true, blink: false },
      cursorConfig,
      true,
      2
    );

    const [element] = children(vnode);
    expect(element!.props.children).toBe("中");
    expect(element!.props.class).toContain("cursor-block");
    expect(element!.props.class).toContain("fixed-cell-wide");
  });

  test("preserves hyperlink and selection classes on a fixed run", () => {
    const vnode = renderLine(
      [
        run({
          text: "➛",
          cellCount: 1,
          fixedWidth: 1,
          selected: true,
          hyperlink: "https://example.test",
        }),
      ],
      0,
      hiddenCursor,
      cursorConfig,
      false,
      1
    );

    const [element] = children(vnode);
    expect(element!.type).toBe("a");
    expect(element!.props.class).toContain("selected");
    expect(element!.props.class).toContain("fixed-cell");
    expect(element!.props.class).toContain("hyperlink");
  });
});
