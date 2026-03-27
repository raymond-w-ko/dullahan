import { describe, expect, test } from "bun:test";
import {
  normalizeWheelDeltaToRows,
  WHEEL_DELTA_MODE_LINE,
  WHEEL_DELTA_MODE_PAGE,
  WHEEL_DELTA_MODE_PIXEL,
} from "./wheel";

describe("normalizeWheelDeltaToRows", () => {
  test("converts pixel deltas using row height", () => {
    expect(
      normalizeWheelDeltaToRows({
        deltaY: 30,
        deltaMode: WHEEL_DELTA_MODE_PIXEL,
        viewportRows: 24,
        rowHeightPx: 15,
        remainder: 0,
      })
    ).toEqual({ rows: 2, remainder: 0 });
  });

  test("accumulates fractional pixel deltas", () => {
    const first = normalizeWheelDeltaToRows({
      deltaY: 5,
      deltaMode: WHEEL_DELTA_MODE_PIXEL,
      viewportRows: 24,
      rowHeightPx: 10,
      remainder: 0,
    });
    expect(first).toEqual({ rows: 0, remainder: 0.5 });

    const second = normalizeWheelDeltaToRows({
      deltaY: 7,
      deltaMode: WHEEL_DELTA_MODE_PIXEL,
      viewportRows: 24,
      rowHeightPx: 10,
      remainder: first.remainder,
    });
    expect(second).toEqual({ rows: 1, remainder: 0.2 });
  });

  test("treats line mode as direct row counts", () => {
    expect(
      normalizeWheelDeltaToRows({
        deltaY: -3,
        deltaMode: WHEEL_DELTA_MODE_LINE,
        viewportRows: 24,
        rowHeightPx: 18,
        remainder: 0,
      })
    ).toEqual({ rows: -3, remainder: 0 });
  });

  test("treats page mode as viewport-sized jumps", () => {
    expect(
      normalizeWheelDeltaToRows({
        deltaY: 1,
        deltaMode: WHEEL_DELTA_MODE_PAGE,
        viewportRows: 37,
        rowHeightPx: 18,
        remainder: 0,
      })
    ).toEqual({ rows: 37, remainder: 0 });
  });

  test("uses ceil for negative fractional totals", () => {
    expect(
      normalizeWheelDeltaToRows({
        deltaY: -7,
        deltaMode: WHEEL_DELTA_MODE_PIXEL,
        viewportRows: 24,
        rowHeightPx: 10,
        remainder: -0.2,
      })
    ).toEqual({ rows: 0, remainder: -0.9 });
  });
});
