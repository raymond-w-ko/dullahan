import { ANTHROPIC_MONO_RANGES } from "./anthropicMonoCoverage.generated";
import { IOSEVKA_TERM_RANGES } from "./iosevkaTermCoverage.generated";

export interface FontCoverageProfile {
  readonly id: string;
  readonly familyNames: readonly string[];
  readonly ranges: readonly (readonly [number, number])[];
}

export const ANTHROPIC_MONO_PROFILE: FontCoverageProfile = {
  id: "anthropic-mono",
  familyNames: ["anthropicmono", "anthropic mono"],
  ranges: ANTHROPIC_MONO_RANGES,
};

export const IOSEVKA_TERM_PROFILE: FontCoverageProfile = {
  id: "iosevka-term",
  familyNames: ["iosevka term"],
  ranges: IOSEVKA_TERM_RANGES,
};

const FONT_COVERAGE_PROFILES: readonly FontCoverageProfile[] = [
  IOSEVKA_TERM_PROFILE,
  ANTHROPIC_MONO_PROFILE,
];

function firstFontFamily(fontFamily: string): string | undefined {
  let quote: "'" | '"' | undefined;
  let escaped = false;
  let end = fontFamily.length;

  for (let i = 0; i < fontFamily.length; i++) {
    const char = fontFamily[i]!;
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (quote) {
      if (char === quote) quote = undefined;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (char === ",") {
      end = i;
      break;
    }
  }

  if (quote || escaped) return undefined;
  let family = fontFamily.slice(0, end).trim();
  if (!family) return undefined;

  const openingQuote = family[0];
  if (openingQuote === "'" || openingQuote === '"') {
    if (family.at(-1) !== openingQuote) return undefined;
    family = family.slice(1, -1);
  } else if (family.includes("'") || family.includes('"')) {
    return undefined;
  }

  return family.replace(/\\(.)/g, "$1").trim() || undefined;
}

function normalizeFamilyName(family: string): string {
  return family.toLowerCase().replace(/\s+/g, " ").trim();
}

export function resolveFontCoverageProfile(
  fontFamily: string
): FontCoverageProfile | undefined {
  const first = firstFontFamily(fontFamily);
  if (!first) return undefined;
  const normalized = normalizeFamilyName(first);
  return FONT_COVERAGE_PROFILES.find((profile) =>
    profile.familyNames.includes(normalized)
  );
}

export function profileHasCodepoint(
  profile: FontCoverageProfile,
  codepoint: number
): boolean {
  let low = 0;
  let high = profile.ranges.length - 1;
  while (low <= high) {
    const middle = (low + high) >>> 1;
    const [start, end] = profile.ranges[middle]!;
    if (codepoint < start) {
      high = middle - 1;
    } else if (codepoint > end) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}

export function textNeedsFontFallback(
  text: string,
  profile: FontCoverageProfile
): boolean {
  for (const char of text) {
    const codepoint = char.codePointAt(0);
    if (codepoint !== undefined && !profileHasCodepoint(profile, codepoint)) {
      return true;
    }
  }
  return false;
}
