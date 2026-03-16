export type ConfigCursorStyle = "block" | "bar" | "underline" | "block_hollow";
export type SnapshotCursorStyle = "block" | "bar" | "underline";

/**
 * Server snapshot style wins for dynamic DECSCUSR updates.
 * Keep the local hollow-block preference only when the server still reports a
 * block-shaped cursor, since the wire protocol does not distinguish hollow vs
 * filled blocks.
 */
export function resolveRenderedCursorStyle(
  configStyle: ConfigCursorStyle,
  snapshotStyle: SnapshotCursorStyle
): ConfigCursorStyle {
  if (snapshotStyle === "block" && configStyle === "block_hollow") {
    return "block_hollow";
  }
  return snapshotStyle;
}
