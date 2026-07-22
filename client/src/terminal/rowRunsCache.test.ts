import { describe, expect, test } from "bun:test";
import { resolveFontCoverageProfile } from "./fontCoverage";
import {
  rowRunsCacheContextChanged,
  type RowRunsCacheContext,
} from "./rowRunsCache";

function context(fontCoverageId: string | null): RowRunsCacheContext {
  return {
    paneId: 1,
    cols: 80,
    altScreen: false,
    theme: "atom-one-dark",
    fontCoverageId,
  };
}

describe("row run cache context", () => {
  test("does not invalidate identical contexts", () => {
    expect(rowRunsCacheContextChanged(context(null), context(null))).toBe(false);
  });

  test("invalidates when entering the Anthropic profile", () => {
    expect(
      rowRunsCacheContextChanged(context(null), context("anthropic-mono"))
    ).toBe(true);
  });

  test("invalidates when leaving the Anthropic profile", () => {
    expect(
      rowRunsCacheContextChanged(context("anthropic-mono"), context(null))
    ).toBe(true);
  });

  test("equivalent Anthropic aliases do not invalidate", () => {
    const compact = resolveFontCoverageProfile("AnthropicMono, monospace")?.id ?? null;
    const spaced = resolveFontCoverageProfile("ANTHROPIC MONO, monospace")?.id ?? null;

    expect(compact).toBe("anthropic-mono");
    expect(spaced).toBe("anthropic-mono");
    expect(rowRunsCacheContextChanged(context(compact), context(spaced))).toBe(false);
  });

  test("invalidates when any non-font render context changes", () => {
    const current = context(null);
    expect(rowRunsCacheContextChanged(current, { ...current, paneId: 2 })).toBe(true);
    expect(rowRunsCacheContextChanged(current, { ...current, cols: 120 })).toBe(true);
    expect(rowRunsCacheContextChanged(current, { ...current, altScreen: true })).toBe(true);
    expect(rowRunsCacheContextChanged(current, { ...current, theme: "nord" })).toBe(true);
  });
});
