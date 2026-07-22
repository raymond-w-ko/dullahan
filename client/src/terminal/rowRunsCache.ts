export interface RowRunsCacheContext {
  paneId: number;
  cols: number;
  altScreen: boolean;
  theme: string;
  fontCoverageId: string | null;
}

export function rowRunsCacheContextChanged(
  current: RowRunsCacheContext,
  next: RowRunsCacheContext
): boolean {
  return (
    current.paneId !== next.paneId ||
    current.cols !== next.cols ||
    current.altScreen !== next.altScreen ||
    current.theme !== next.theme ||
    current.fontCoverageId !== next.fontCoverageId
  );
}
