import { expect, test } from "bun:test";
import type { TerminalImagePlacement } from "../../../protocol/schema/messages";
import {
  terminalImageCropStyle,
  terminalImagePlacementStyle,
} from "./imageStyles";

function image(overrides: Partial<TerminalImagePlacement> = {}): TerminalImagePlacement {
  return {
    imageKey: "1-1-rgba-10x10-a",
    url: "/api/images/1/1-1-rgba-10x10-a",
    protocol: "kitty",
    paneId: 1,
    imageId: 1,
    placementId: 1,
    viewportCol: 2,
    viewportRow: 3,
    gridCols: 4,
    gridRows: 5,
    imageWidth: 10,
    imageHeight: 20,
    pixelWidth: 0,
    pixelHeight: 0,
    sourceX: 0,
    sourceY: 0,
    sourceWidth: 10,
    sourceHeight: 20,
    z: 1,
    format: "rgba",
    generation: 1,
    ...overrides,
  };
}

test("terminalImagePlacementStyle uses cell-relative geometry", () => {
  expect(terminalImagePlacementStyle(image({ xOffset: 6, yOffset: 7 }))).toEqual({
    left: "calc(2 * var(--cell-width, 1ch) + 6px)",
    top: "calc(3 * var(--term-line-height) + 7px)",
    width: "calc(4 * var(--cell-width, 1ch))",
    height: "calc(5 * var(--term-line-height))",
    zIndex: 1001,
  });
});

test("terminalImageCropStyle returns undefined for full image", () => {
  expect(terminalImageCropStyle(image())).toBeUndefined();
});

test("terminalImageCropStyle expands source rect crop", () => {
  expect(
    terminalImageCropStyle(image({ sourceX: 5, sourceY: 4, sourceWidth: 5, sourceHeight: 10 }))
  ).toEqual({
    position: "absolute",
    left: "-100%",
    top: "-40%",
    width: "200%",
    height: "200%",
  });
});
