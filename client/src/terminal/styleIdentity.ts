import type { Cell } from "../../../protocol/schema/cell";
import { DEFAULT_STYLE, encodeStyle } from "../../../protocol/schema/style";
import type { Style, StyleTable } from "../../../protocol/schema/style";

export interface StyleIdentityState {
  nextStyleId: number;
  keyToId: Map<string, number>;
  idToKey: Map<number, string>;
}

export function createStyleIdentityState(): StyleIdentityState {
  return {
    nextStyleId: 1,
    keyToId: new Map(),
    idToKey: new Map(),
  };
}

export function cloneStyleIdentityState(state: StyleIdentityState): StyleIdentityState {
  return {
    nextStyleId: state.nextStyleId,
    keyToId: new Map(state.keyToId),
    idToKey: new Map(state.idToKey),
  };
}

export function styleFingerprint(style: Style): string {
  const bytes = encodeStyle(style);
  let out = "";
  for (const b of bytes) {
    out += b.toString(16).padStart(2, "0");
  }
  return out;
}

export function ensureDefaultStyle(styles: StyleTable, fallback?: Style): void {
  if (!styles.has(0)) {
    styles.set(0, fallback ?? DEFAULT_STYLE);
  }
}

/**
 * Convert payload-local style IDs into stable canonical IDs derived from style bytes.
 */
export function canonicalizePayloadStyles(
  payloadStyles: StyleTable,
  canonicalStyles: StyleTable,
  identity: StyleIdentityState,
): Map<number, number> {
  ensureDefaultStyle(canonicalStyles, payloadStyles.get(0));
  const payloadToCanonical = new Map<number, number>();

  for (const [payloadId, style] of payloadStyles) {
    if (payloadId === 0) continue;

    const key = styleFingerprint(style);
    let canonicalId = identity.keyToId.get(key);
    if (canonicalId === undefined) {
      canonicalId = identity.nextStyleId++;
      identity.keyToId.set(key, canonicalId);
      identity.idToKey.set(canonicalId, key);
    }

    payloadToCanonical.set(payloadId, canonicalId);
    if (!canonicalStyles.has(canonicalId)) {
      canonicalStyles.set(canonicalId, style);
    }
  }

  return payloadToCanonical;
}

/**
 * Rewrite decoded cells from payload style IDs to canonical style IDs.
 * Returns number of non-zero style IDs that had no mapping.
 */
export function remapCellsToCanonicalStyles(
  cells: Cell[],
  payloadToCanonical: Map<number, number>,
): number {
  let missing = 0;
  for (const cell of cells) {
    if (cell.styleId === 0) continue;
    const canonicalId = payloadToCanonical.get(cell.styleId);
    if (canonicalId === undefined) {
      missing += 1;
      continue;
    }
    cell.styleId = canonicalId;
  }
  return missing;
}

/**
 * Drop canonical styles no longer referenced by any cached rows.
 */
export function pruneUnusedStyles(
  styles: StyleTable,
  identity: StyleIdentityState,
  usedStyleIds: Set<number>,
): void {
  for (const styleId of styles.keys()) {
    if (styleId === 0) continue;
    if (usedStyleIds.has(styleId)) continue;

    styles.delete(styleId);
    const key = identity.idToKey.get(styleId);
    if (key !== undefined) {
      identity.idToKey.delete(styleId);
      identity.keyToId.delete(key);
    }
  }
}
