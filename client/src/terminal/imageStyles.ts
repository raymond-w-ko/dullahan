import type { TerminalImagePlacement } from "../../../protocol/schema/messages";
import type { JSX } from "preact";
import { resolveTerminalImageZIndex } from "./imageZIndex";

export type TerminalImagePlacementStyle = JSX.CSSProperties;
export type TerminalImageCropStyle = JSX.CSSProperties;

export function terminalImagePlacementStyle(image: TerminalImagePlacement): TerminalImagePlacementStyle {
  return {
    left: `calc(${image.viewportCol} * var(--cell-width, 1ch) + ${image.xOffset ?? 0}px)`,
    top: `calc(${image.viewportRow} * var(--term-line-height) + ${image.yOffset ?? 0}px)`,
    width: `calc(${image.gridCols} * var(--cell-width, 1ch))`,
    height: `calc(${image.gridRows} * var(--term-line-height))`,
    zIndex: resolveTerminalImageZIndex(image.z),
  };
}

export function terminalImageCropStyle(image: TerminalImagePlacement): TerminalImageCropStyle | undefined {
  if (
    image.imageWidth <= 0 ||
    image.imageHeight <= 0 ||
    image.sourceWidth <= 0 ||
    image.sourceHeight <= 0 ||
    (image.sourceX === 0 &&
      image.sourceY === 0 &&
      image.sourceWidth === image.imageWidth &&
      image.sourceHeight === image.imageHeight)
  ) {
    return undefined;
  }

  return {
    position: "absolute",
    left: `${-(image.sourceX / image.sourceWidth) * 100}%`,
    top: `${-(image.sourceY / image.sourceHeight) * 100}%`,
    width: `${(image.imageWidth / image.sourceWidth) * 100}%`,
    height: `${(image.imageHeight / image.sourceHeight) * 100}%`,
  };
}
