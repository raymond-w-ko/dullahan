export const WHEEL_DELTA_MODE_PIXEL = 0;
export const WHEEL_DELTA_MODE_LINE = 1;
export const WHEEL_DELTA_MODE_PAGE = 2;
const DEFAULT_ROW_HEIGHT_PX = 16;

export interface WheelDeltaToRowsInput {
  deltaY: number;
  deltaMode: number;
  viewportRows: number;
  rowHeightPx: number;
  remainder: number;
}

export interface WheelDeltaToRowsResult {
  rows: number;
  remainder: number;
}

export function normalizeWheelDeltaToRows({
  deltaY,
  deltaMode,
  viewportRows,
  rowHeightPx,
  remainder,
}: WheelDeltaToRowsInput): WheelDeltaToRowsResult {
  if (!Number.isFinite(deltaY) || deltaY === 0) {
    return { rows: 0, remainder };
  }

  const safeViewportRows = Math.max(1, Math.floor(viewportRows) || 0);
  const safeRowHeightPx =
    Number.isFinite(rowHeightPx) && rowHeightPx > 0
      ? rowHeightPx
      : DEFAULT_ROW_HEIGHT_PX;

  // Browsers report wheel deltas in pixels, lines, or pages. Convert all of
  // them into "terminal rows", then carry fractional rows forward so smooth
  // trackpad gestures still accumulate into precise whole-row scroll commands.
  let deltaRows: number;
  switch (deltaMode) {
    case WHEEL_DELTA_MODE_PIXEL:
      deltaRows = deltaY / safeRowHeightPx;
      break;
    case WHEEL_DELTA_MODE_PAGE:
      deltaRows = deltaY * safeViewportRows;
      break;
    case WHEEL_DELTA_MODE_LINE:
    default:
      deltaRows = deltaY;
      break;
  }

  const totalRows = remainder + deltaRows;
  const rawRows =
    totalRows > 0 ? Math.floor(totalRows) : Math.ceil(totalRows);
  const rows = Object.is(rawRows, -0) ? 0 : rawRows;
  const rawRemainder = totalRows - rows;
  const nextRemainder =
    Math.abs(rawRemainder) < 1e-9
      ? 0
      : Math.round(rawRemainder * 1e9) / 1e9;

  return {
    rows,
    remainder: nextRemainder,
  };
}
