import type { Cell } from "../../../protocol/schema/cell";
import { DEFAULT_STYLE, encodeFlags } from "../../../protocol/schema/style";
import type { Style, StyleTable } from "../../../protocol/schema/style";

interface StyleIdentityEntry {
  canonicalId: number;
  style: Style;
}

export interface StyleIdentityState {
  nextStyleId: number;
  hashToEntries: Map<number, StyleIdentityEntry[]>;
  idToHash: Map<number, number>;
}

export function createStyleIdentityState(): StyleIdentityState {
  return {
    nextStyleId: 1,
    hashToEntries: new Map(),
    idToHash: new Map(),
  };
}

export function cloneStyleIdentityState(state: StyleIdentityState): StyleIdentityState {
  const hashToEntries = new Map<number, StyleIdentityEntry[]>();
  for (const [hash, entries] of state.hashToEntries) {
    hashToEntries.set(hash, entries.slice());
  }
  return {
    nextStyleId: state.nextStyleId,
    hashToEntries,
    idToHash: new Map(state.idToHash),
  };
}

function hashStep(hash: number, byte: number): number {
  return Math.imul((hash ^ (byte & 0xff)) >>> 0, 0x01000193) >>> 0;
}

function hashColor(hash: number, color: Style["fgColor"]): number {
  let next = hashStep(hash, color.tag);
  if (color.tag === 1) {
    next = hashStep(next, color.index);
    next = hashStep(next, 0);
    next = hashStep(next, 0);
    return next;
  }
  if (color.tag === 2) {
    next = hashStep(next, color.r);
    next = hashStep(next, color.g);
    next = hashStep(next, color.b);
    return next;
  }
  next = hashStep(next, 0);
  next = hashStep(next, 0);
  next = hashStep(next, 0);
  return next;
}

function hashStyle(style: Style): number {
  let hash = 0x811c9dc5;
  hash = hashColor(hash, style.fgColor);
  hash = hashColor(hash, style.bgColor);
  hash = hashColor(hash, style.underlineColor);
  const flags = encodeFlags(style.flags);
  hash = hashStep(hash, flags & 0xff);
  hash = hashStep(hash, (flags >> 8) & 0xff);
  return hash >>> 0;
}

function colorsEqual(a: Style["fgColor"], b: Style["fgColor"]): boolean {
  if (a.tag !== b.tag) return false;
  if (a.tag === 0) return true;
  if (a.tag === 1 && b.tag === 1) {
    return a.index === b.index;
  }
  if (a.tag === 2 && b.tag === 2) {
    return a.r === b.r && a.g === b.g && a.b === b.b;
  }
  return false;
}

function stylesEqual(a: Style, b: Style): boolean {
  if (!colorsEqual(a.fgColor, b.fgColor)) return false;
  if (!colorsEqual(a.bgColor, b.bgColor)) return false;
  if (!colorsEqual(a.underlineColor, b.underlineColor)) return false;
  return encodeFlags(a.flags) === encodeFlags(b.flags);
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

    const hash = hashStyle(style);
    let entries = identity.hashToEntries.get(hash);
    let canonicalId: number | undefined;

    if (entries) {
      for (const entry of entries) {
        if (stylesEqual(entry.style, style)) {
          canonicalId = entry.canonicalId;
          break;
        }
      }
    }

    if (canonicalId === undefined) {
      canonicalId = identity.nextStyleId++;
      if (!entries) {
        entries = [];
        identity.hashToEntries.set(hash, entries);
      }
      entries.push({ canonicalId, style });
      identity.idToHash.set(canonicalId, hash);
    }

    payloadToCanonical.set(payloadId, canonicalId);
    if (!canonicalStyles.has(canonicalId)) {
      canonicalStyles.set(canonicalId, style);
    }
  }

  return payloadToCanonical;
}

/**
 * Convert payload-local style IDs into canonical IDs without cloning the full
 * canonical style table. New or missing canonical styles are written to
 * `styleOverlay`, while lookups continue to read from `baseStyles`.
 */
export function canonicalizePayloadStylesWithOverlay(
  payloadStyles: StyleTable,
  baseStyles: StyleTable,
  styleOverlay: StyleTable,
  identity: StyleIdentityState,
): Map<number, number> {
  if (!baseStyles.has(0) && !styleOverlay.has(0)) {
    styleOverlay.set(0, payloadStyles.get(0) ?? DEFAULT_STYLE);
  }

  const payloadToCanonical = new Map<number, number>();

  for (const [payloadId, style] of payloadStyles) {
    if (payloadId === 0) continue;

    const hash = hashStyle(style);
    let entries = identity.hashToEntries.get(hash);
    let canonicalId: number | undefined;

    if (entries) {
      for (const entry of entries) {
        if (stylesEqual(entry.style, style)) {
          canonicalId = entry.canonicalId;
          break;
        }
      }
    }

    if (canonicalId === undefined) {
      canonicalId = identity.nextStyleId++;
      if (!entries) {
        entries = [];
        identity.hashToEntries.set(hash, entries);
      }
      entries.push({ canonicalId, style });
      identity.idToHash.set(canonicalId, hash);
    }

    payloadToCanonical.set(payloadId, canonicalId);
    if (!baseStyles.has(canonicalId) && !styleOverlay.has(canonicalId)) {
      styleOverlay.set(canonicalId, style);
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
    const hash = identity.idToHash.get(styleId);
    if (hash !== undefined) {
      identity.idToHash.delete(styleId);
      const entries = identity.hashToEntries.get(hash);
      if (entries) {
        const idx = entries.findIndex((entry) => entry.canonicalId === styleId);
        if (idx >= 0) {
          entries.splice(idx, 1);
        }
        if (entries.length === 0) {
          identity.hashToEntries.delete(hash);
        }
      }
    }
  }
}
