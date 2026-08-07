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

  test("invalidates when entering a font coverage profile", () => {
    expect(
      rowRunsCacheContextChanged(context(null), context("iosevka-term"))
    ).toBe(true);
  });

  test("invalidates when leaving a font coverage profile", () => {
    expect(
      rowRunsCacheContextChanged(context("iosevka-term"), context(null))
    ).toBe(true);
  });

  test("equivalent Iosevka family spelling does not invalidate", () => {
    const regular =
      resolveFontCoverageProfile("Iosevka Term, monospace")?.id ?? null;
    const spaced =
      resolveFontCoverageProfile("IOSEVKA   TERM, monospace")?.id ?? null;

    expect(regular).toBe("iosevka-term");
    expect(spaced).toBe("iosevka-term");
    expect(rowRunsCacheContextChanged(context(regular), context(spaced))).toBe(
      false
    );
  });

  test("invalidates when switching between known profiles", () => {
    expect(
      rowRunsCacheContextChanged(
        context("iosevka-term"),
        context("anthropic-mono")
      )
    ).toBe(true);
  });

  test("invalidates when any non-font render context changes", () => {
    const current = context(null);
    expect(rowRunsCacheContextChanged(current, { ...current, paneId: 2 })).toBe(true);
    expect(rowRunsCacheContextChanged(current, { ...current, cols: 120 })).toBe(true);
    expect(rowRunsCacheContextChanged(current, { ...current, altScreen: true })).toBe(true);
    expect(rowRunsCacheContextChanged(current, { ...current, theme: "nord" })).toBe(true);
  });
});
