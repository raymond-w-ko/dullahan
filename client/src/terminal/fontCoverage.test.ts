import { describe, expect, test } from "bun:test";
import {
  ANTHROPIC_MONO_PROFILE,
  profileHasCodepoint,
  resolveFontCoverageProfile,
  textNeedsFontFallback,
} from "./fontCoverage";
import {
  ANTHROPIC_MONO_CODEPOINT_COUNT,
  ANTHROPIC_MONO_RANGE_COUNT,
  ANTHROPIC_MONO_RANGES,
} from "./anthropicMonoCoverage.generated";

describe("Anthropic Mono coverage", () => {
  test("contains the generated coverage totals", () => {
    const count = ANTHROPIC_MONO_RANGES.reduce(
      (total, [start, end]) => total + end - start + 1,
      0
    );
    expect(ANTHROPIC_MONO_CODEPOINT_COUNT).toBe(603);
    expect(ANTHROPIC_MONO_RANGE_COUNT).toBe(125);
    expect(ANTHROPIC_MONO_RANGES).toHaveLength(125);
    expect(count).toBe(603);
  });

  test("finds representative present and missing codepoints", () => {
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x20)).toBe(true);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x7e)).toBe(true);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x2500)).toBe(true);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x2588)).toBe(true);

    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x279b)).toBe(false);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x0410)).toBe(false);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0xea61)).toBe(false);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x2504)).toBe(false);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x4e2d)).toBe(false);
    expect(profileHasCodepoint(ANTHROPIC_MONO_PROFILE, 0x1f600)).toBe(false);
  });

  test("checks every codepoint in a grapheme", () => {
    expect(textNeedsFontFallback("A", ANTHROPIC_MONO_PROFILE)).toBe(false);
    expect(textNeedsFontFallback("A\u{0410}", ANTHROPIC_MONO_PROFILE)).toBe(true);
  });
});

describe("font coverage profile selection", () => {
  test.each([
    "AnthropicMono, Iosevka Term, monospace",
    "Anthropic Mono, Iosevka Term",
    "  'Anthropic Mono' , monospace",
    '\"anthropicmono\", monospace',
    "ANTHROPICMONO, monospace",
    "ANTHROPIC   MONO, monospace",
  ])("recognizes Anthropic Mono as the first family: %s", (fontFamily) => {
    expect(resolveFontCoverageProfile(fontFamily)?.id).toBe("anthropic-mono");
  });

  test.each([
    "Iosevka Term, AnthropicMono, monospace",
    "monospace",
    "Anthropic-Mono, monospace",
    "Anthropic_Mono, monospace",
    "",
    "'Anthropic Mono, monospace",
    'Anthropic\"Mono, monospace',
  ])("does not activate for a different or malformed first family: %s", (fontFamily) => {
    expect(resolveFontCoverageProfile(fontFamily)).toBeUndefined();
  });
});
