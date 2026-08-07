import { describe, expect, test } from "bun:test";
import {
  ANTHROPIC_MONO_PROFILE,
  IOSEVKA_TERM_PROFILE,
  profileHasCodepoint,
  resolveFontCoverageProfile,
  textNeedsFontFallback,
} from "./fontCoverage";
import {
  ANTHROPIC_MONO_CODEPOINT_COUNT,
  ANTHROPIC_MONO_RANGE_COUNT,
  ANTHROPIC_MONO_RANGES,
} from "./anthropicMonoCoverage.generated";
import {
  IOSEVKA_TERM_CODEPOINT_COUNT,
  IOSEVKA_TERM_RANGE_COUNT,
  IOSEVKA_TERM_RANGES,
} from "./iosevkaTermCoverage.generated";

describe("Iosevka Term coverage", () => {
  test("contains the generated coverage totals", () => {
    const count = IOSEVKA_TERM_RANGES.reduce(
      (total, [start, end]) => total + end - start + 1,
      0
    );
    expect(IOSEVKA_TERM_CODEPOINT_COUNT).toBe(7581);
    expect(IOSEVKA_TERM_RANGE_COUNT).toBe(300);
    expect(IOSEVKA_TERM_RANGES).toHaveLength(300);
    expect(count).toBe(7581);
  });

  test("finds representative present and missing codepoints", () => {
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x20)).toBe(true);
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x7e)).toBe(true);
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x0410)).toBe(true);
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x2504)).toBe(true);
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x2588)).toBe(true);

    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x279b)).toBe(false);
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0xea61)).toBe(false);
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x4e2d)).toBe(false);
    expect(profileHasCodepoint(IOSEVKA_TERM_PROFILE, 0x1f600)).toBe(false);
  });

  test("checks every codepoint in a grapheme", () => {
    expect(textNeedsFontFallback("A\u{0410}", IOSEVKA_TERM_PROFILE)).toBe(false);
    expect(textNeedsFontFallback("A\u{4E2D}", IOSEVKA_TERM_PROFILE)).toBe(true);
  });
});

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
    "Iosevka Term, AnthropicMono, monospace",
    "  'Iosevka Term' , monospace",
    '"iosevka term", monospace',
    "IOSEVKA   TERM, monospace",
  ])("recognizes Iosevka Term as the first family: %s", (fontFamily) => {
    expect(resolveFontCoverageProfile(fontFamily)?.id).toBe("iosevka-term");
  });

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
    "monospace",
    "IosevkaTerm, monospace",
    "Iosevka-Term, monospace",
    "Anthropic-Mono, monospace",
    "Anthropic_Mono, monospace",
    "",
    "'Anthropic Mono, monospace",
    'Anthropic\"Mono, monospace',
  ])("does not activate for a different or malformed first family: %s", (fontFamily) => {
    expect(resolveFontCoverageProfile(fontFamily)).toBeUndefined();
  });
});
