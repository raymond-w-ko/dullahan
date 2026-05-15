const IMAGE_Z_BASE = 1000;
const IMAGE_Z_MAX = 2147483647;

export function resolveTerminalImageZIndex(kittyZ: number): number {
  const z = Math.trunc(Number.isFinite(kittyZ) ? kittyZ : 0);
  return Math.max(0, Math.min(IMAGE_Z_MAX, IMAGE_Z_BASE + z));
}
